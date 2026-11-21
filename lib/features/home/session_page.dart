import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_theme.dart';
import '../../core/calibration.dart';
import '../../core/db.dart';
import '../../core/image_pipeline.dart';
import '../../core/models.dart';
import '../../core/storage.dart';
import '../capture/capture_page.dart';
import '../capture/calibrate_page.dart';
import '../viewer/photo_view_page.dart';

/// 会话详情：一个参照（家里）+ 多个目标（厂里 / 其他环境）。
///
/// 三条约定：
/// * 图像重活全部走 image_pipeline（后台 isolate），UI 线程不解码大图；
/// * 重新标定 / 换参照图会让旧的对比结果失效，不会一边改白点一边留着旧 ΔE；
/// * 任何耗时操作期间，行内按钮一起禁用，避免并发解码和并发写库。
class SessionPage extends StatefulWidget {
  const SessionPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  SessionDetail? _detail;
  bool _busy = false;
  String? _progress;
  int _resultIndex = 0;
  bool _showBefore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final SessionDetail? detail = await AppDb.instance.detail(widget.sessionId);
    if (!mounted) return;
    setState(() => _detail = detail);
  }

  // ------------------------------------------------------------ 采集

  Future<void> _pick(String role, {required bool camera}) async {
    if (_busy) return;
    if (camera) {
      final String? path = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => CapturePage(role: role, sessionId: widget.sessionId),
        ),
      );
      if (path == null || !mounted) return;
      await _saveCapture(role, path, 'camera');
      return;
    }
    final XFile? picked =
        await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2400);
    if (picked == null || !mounted) return;
    await _saveCapture(role, picked.path, 'upload');
  }

  Future<void> _saveCapture(String role, String sourcePath, String source) async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String id = const Uuid().v4();
    final String ext =
        p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final String dest =
        p.join(dir.path, 'captures', widget.sessionId, id + '_' + role + ext);
    await File(dest).create(recursive: true);
    await File(sourcePath).copy(dest);
    if (source == 'camera') {
      try {
        final File tmp = File(sourcePath);
        if (await tmp.exists() && !tmp.path.startsWith(dir.path)) {
          await tmp.delete();
        }
      } catch (_) {}
    }

    await AppDb.instance.insertCapture(Capture(
      id: id,
      sessionId: widget.sessionId,
      role: role,
      imagePath: dest,
      source: source,
      createdAt: DateTime.now(),
    ));
    await _load();
    if (!mounted) return;
    await _askLocation(id);
  }

  /// 给这张图打个「光」的标签：同一块样品换几个光源拍，才能看出是不是同色异谱。
  Future<void> _askLocation(String captureId) async {
    final List<String> presets = <String>[
      '家里·顶灯',
      '家里·窗边自然光',
      '门店·射灯',
      '门店·顶灯',
      '室外',
    ];
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('这张是在哪拍的？什么光？（可跳过）',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            ...presets.map((String p) => ListTile(
                  dense: true,
                  title: Text(p, style: const TextStyle(fontSize: 14)),
                  onTap: () => Navigator.pop(ctx, p),
                )),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined, size: 18),
              title: const Text('自定义…', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, '__custom__'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.close, size: 18),
              title: const Text('跳过', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    String label = picked;
    if (picked == '__custom__') {
      final TextEditingController controller = TextEditingController();
      final String? custom = await showDialog<String>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('光源 / 地点'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '比如：门店东侧射灯'),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (custom == null || custom.isEmpty) return;
      label = custom;
    }
    await AppDb.instance.updateCaptureLocation(captureId, label);
    await _load();
  }

  /// 换参照图：替换而不是再插一张。
  ///
  /// 以前「换图」是追加一条 reference，而详情页只认第一条，于是换了等于没换，
  /// 数据库里还留着一张看不见的参照。
  Future<void> _replaceReference() async {
    final Capture? old = _detail?.reference;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重拍参照图？'),
        content: const Text('旧参照图、以及所有基于它的对比结果都会被删掉。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('重拍'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (old != null) {
      await _deleteCaptureAndFiles(old);
    }
    if (!mounted) return;
    await _pick('reference', camera: true);
  }

  Future<void> _deleteCaptureAndFiles(Capture capture) async {
    final SessionDetail? detail = _detail;
    final List<String> extra = <String>[];
    final Comparison? own = detail?.comparisons[capture.id];
    if (own != null) extra.add(own.processedPath);

    await AppDb.instance.deleteCapture(capture.id, widget.sessionId);
    for (final String? path in <String?>[
      capture.imagePath,
      capture.calibratedPath,
      ...extra,
    ]) {
      if (path == null) continue;
      try {
        final File f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _confirmDelete(Capture capture) async {
    if (_busy) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除这张图？'),
        content: Text(capture.isReference
            ? '参照图删掉后，基于它的对比结果也会一起删掉。'
            : '对应的对比结果会一起删掉。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _deleteCaptureAndFiles(capture);
    await _load();
    if (mounted) showSnack(context, '已删除');
  }

  // ------------------------------------------------------------ 标定

  Future<void> _calibrate(Capture capture) async {
    if (_busy) return;
    final Calibration? calibration =
        await Navigator.of(context).push<Calibration>(
      MaterialPageRoute<Calibration>(
        builder: (_) => CalibratePage(imagePath: capture.imagePath),
      ),
    );
    if (calibration == null || !mounted) return;
    final WhitePoint white = calibration.white;
    final WhitePoint? checker = calibration.checker;
    if (!white.isValid) {
      showSnack(context, '这块白太暗了，换个更亮的白纸', error: true);
      return;
    }

    setState(() {
      _busy = true;
      _progress = '标定中…';
    });
    try {
      // 只记白点这一个数值，**不生成、不改写任何照片**。
      // 家里那张是基准，颜色必须保持现场看到的样子；工地那张在对比时才临时拉过来。
      // 旧版本会写一张 _calibrated.jpg，等于把要对比的照片改了色 —— 已废弃。
      await AppDb.instance.updateCaptureCalibration(
        capture.id,
        whiteR: white.r.round(),
        whiteG: white.g.round(),
        whiteB: white.b.round(),
        checkR: checker?.r.round(),
        checkG: checker?.g.round(),
        checkB: checker?.b.round(),
      );
      // 顺手清掉旧版本留下的校正图，别让界面再读到它
      final String stale = p.join(
          (await getApplicationDocumentsDirectory()).path,
          'captures',
          widget.sessionId,
          capture.id + '_calibrated.jpg');
      try {
        final File staleFile = File(stale);
        if (await staleFile.exists()) await staleFile.delete();
      } catch (_) {}
      // 白点变了，旧结果必须失效，否则界面会拿新白点配旧 ΔE
      if (capture.isReference) {
        await AppDb.instance.invalidateComparisons(widget.sessionId);
      } else {
        await AppDb.instance.invalidateComparisonOf(widget.sessionId, capture.id);
      }
      _resultIndex = 0;
      await _load();
      if (mounted) showSnack(context, '已记录白点 ' + white.toString() + '（照片不会被改动）');
    } catch (error) {
      if (mounted) showSnack(context, '标定失败：' + error.toString(), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  // ------------------------------------------------------------ 对比

  Future<void> _runCompare(Capture reference, Capture target) async {
    final CompareOutcome outcome = await compareFiles(
      referenceRawPath: reference.imagePath,
      targetPath: target.imagePath,
      refR: reference.whiteR!,
      refG: reference.whiteG!,
      refB: reference.whiteB!,
      targetR: target.whiteR!,
      targetG: target.whiteG!,
      targetB: target.whiteB!,
      refCheckR: reference.checkR,
      refCheckG: reference.checkG,
      refCheckB: reference.checkB,
      targetCheckR: target.checkR,
      targetCheckG: target.checkG,
      targetCheckB: target.checkB,
    );

    final Directory dir = await getApplicationDocumentsDirectory();
    final String processedPath = p.join(
        dir.path, 'captures', widget.sessionId, target.id + '_matched.jpg');
    await File(processedPath).writeAsBytes(outcome.jpeg);

    await AppDb.instance.upsertComparison(Comparison(
      id: const Uuid().v4(),
      sessionId: widget.sessionId,
      referenceCaptureId: reference.id,
      targetCaptureId: target.id,
      processedPath: processedPath,
      deltaE: double.parse(outcome.deltaE.toStringAsFixed(2)),
      deltaEBefore: double.parse(outcome.deltaEBefore.toStringAsFixed(2)),
      errorFloor: double.parse(outcome.errorFloor.toStringAsFixed(2)),
      createdAt: DateTime.now(),
    ));
  }

  Future<void> _compareOne(Capture target) async {
    if (_busy) return;
    final Capture? reference = _detail?.reference;
    if (reference == null) {
      showSnack(context, '先拍/传一张参照图', error: true);
      return;
    }
    if (!reference.isCalibrated || !target.isCalibrated) {
      showSnack(context, '两张图都要先标定（框选白纸）', error: true);
      return;
    }
    setState(() {
      _busy = true;
      _progress = '对比中…';
    });
    try {
      await _runCompare(reference, target);
      await _load();
      if (mounted) showSnack(context, '完成');
    } catch (error) {
      if (mounted) showSnack(context, '对比失败：' + error.toString(), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _compareAll() async {
    if (_busy) return;
    final SessionDetail? detail = _detail;
    final Capture? reference = detail?.reference;
    if (detail == null || reference == null) return;
    if (!reference.isCalibrated) {
      showSnack(context, '参照图还没标定', error: true);
      return;
    }
    final List<Capture> pending = detail.targets
        .where((Capture t) => t.isCalibrated && !detail.comparisons.containsKey(t.id))
        .toList();
    if (pending.isEmpty) {
      showSnack(context, '没有待对比的目标（或都没标定）');
      return;
    }
    setState(() {
      _busy = true;
      _progress = '0/' + pending.length.toString();
    });
    int done = 0;
    int failed = 0;
    for (final Capture target in pending) {
      try {
        await _runCompare(reference, target);
        done++;
      } catch (_) {
        failed++;
      }
      final int current = done + failed;
      if (mounted) setState(() => _progress = current.toString() + '/' + pending.length.toString());
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
    });
    showSnack(
      context,
      failed == 0 ? '已对比 ' + done.toString() + ' 个目标' : '完成 ' + done.toString() + ' 个，失败 ' + failed.toString() + ' 个',
      error: failed > 0,
    );
  }

  // ------------------------------------------------------------ 导出

  void _openViewer(List<String> paths, List<String> captions, int index) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PhotoViewPage(
        items: paths,
        captions: captions,
        initialIndex: index,
      ),
    ));
  }

  Future<void> _export() async {
    if (_busy) return;
    final SessionDetail? detail = _detail;
    final Capture? reference = detail?.reference;
    if (detail == null || reference == null || detail.comparisons.isEmpty) return;

    setState(() {
      _busy = true;
      _progress = '生成报告…';
    });
    try {
      final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
      int index = 0;
      for (final Capture target in detail.targets) {
        final Comparison? comparison = detail.comparisons[target.id];
        if (comparison == null) continue;
        index++;
        rows.add(<String, Object?>{
          'before': target.imagePath,
          'after': comparison.processedPath,
          'label': 'T' + index.toString() + '  dE ' +
              comparison.deltaEBefore.toString() + ' -> ' + comparison.deltaE.toString(),
        });
      }
      if (rows.isEmpty) {
        if (mounted) showSnack(context, '没有可导出的对比', error: true);
        return;
      }

      final Uint8List jpeg = await buildReportBytes(
        referencePath: reference.imagePath,
        rows: rows,
      );

      final Directory dir = await exportDir();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final String safeName =
          detail.session.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final String fileName = safeName + '_' + stamp + '.jpg';
      final File file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(jpeg);

      final bool inGallery = await saveToGallery(file.path);

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('已保存'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    inGallery ? Icons.check_circle : Icons.error_outline,
                    size: 18,
                    color: inGallery ? AppColors.success : AppColors.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      inGallery
                          ? '已存到相册「ColorMatch」相簿（卸载不丢）'
                          : '相册没存成（权限被拒或空间不够）',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('应用目录（临时，卸载会删）:',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(fileName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SelectableText(prettyPath(dir.path),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Clipboard.setData(
                    ClipboardData(text: p.join(dir.path, fileName)));
                Navigator.pop(ctx);
                showSnack(context, '路径已复制');
              },
              child: const Text('复制路径'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await SharePlus.instance
                    .share(ShareParams(files: <XFile>[XFile(file.path)]));
              },
              child: const Text('分享'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('好')),
          ],
        ),
      );
    } catch (error) {
      if (mounted) showSnack(context, '导出失败：' + error.toString(), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final SessionDetail? detail = _detail;
    return Scaffold(
      appBar: buildAppBar(
        detail?.session.name ?? '对比',
        actions: <Widget>[
          if (detail != null && detail.comparisons.isNotEmpty)
            IconButton(
              onPressed: _busy ? null : _export,
              icon: const Icon(Icons.save_alt),
              tooltip: '保存对比图到本地',
            ),
        ],
      ),
      body: detail == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xl),
              children: <Widget>[
                _sectionTitle('参照（家里）'),
                _captureRow(detail.reference,
                    role: 'reference', title: '参照图', isReference: true),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: <Widget>[
                    _sectionTitle('目标（' + detail.targets.length.toString() + '）'),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _busy ? null : _addTarget,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                if (detail.targets.isEmpty)
                  _emptyRow('还没有目标图，点「添加」拍厂里的样品')
                else
                  ...detail.targets.map((Capture t) => _captureRow(
                        t,
                        role: 'target',
                        title: '目标 ' + t.shortId,
                        comparison: detail.comparisons[t.id],
                      )),
                const SizedBox(height: AppSpacing.md),
                if (detail.targets.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _compareAll,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.compare),
                      label: Text(_busy
                          ? (_progress ?? '处理中…')
                          : '全部对比（' + detail.pendingCount.toString() + ' 个待处理）'),
                    ),
                  ),
                if (detail.comparisons.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.lg),
                  _resultSection(detail),
                ],
              ],
            ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, top: AppSpacing.xs),
      child: Text(text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
    );
  }

  Widget _emptyRow(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line(context)),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
    );
  }

  Widget _captureRow(
    Capture? capture, {
    required String role,
    required String title,
    bool isReference = false,
    Comparison? comparison,
  }) {
    if (capture == null) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.line(context)),
        ),
        child: Row(
          children: <Widget>[
            _thumbPlaceholder(),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text('还没拍',
                  style: TextStyle(fontSize: 12, color: AppColors.sub(context))),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pick(role, camera: true),
              icon: const Icon(Icons.camera_alt_outlined, size: 16),
              label: const Text('拍照'),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10)),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _busy ? null : () => _pick(role, camera: false),
              icon: const Icon(Icons.photo_library_outlined, size: 20),
              tooltip: '从相册选',
            ),
          ],
        ),
      );
    }

    // 缩略图永远显示原图：标定只是记了个白点，没有「被改过的版本」要展示
    final String shown = capture.imagePath;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            onTap: () => _openViewer(
              <String>[shown, capture.imagePath],
              <String>[
                comparison != null ? title + '（校正后）' : title,
                title + '（原始）',
              ],
              0,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(shown),
                  width: 84,
                  height: 84,
                  cacheWidth: 252,
                  fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    if (comparison != null)
                      Text('ΔE ' + comparison.deltaE.toString(),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.success)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  capture.isCalibrated
                      ? '白点 (' +
                          capture.whiteR.toString() + ', ' +
                          capture.whiteG.toString() + ', ' +
                          capture.whiteB.toString() + ')' +
                          (capture.hasChecker ? '　·　已标已知物' : '') +
                          (capture.location.isEmpty ? '' : '　·　' + capture.location)
                      : (capture.location.isEmpty ? '未标定' : '未标定　·　' + capture.location),
                  style: TextStyle(
                      fontSize: 11,
                      color: capture.isCalibrated
                          ? AppColors.sub(context)
                          : AppColors.warning),
                ),
                Wrap(
                  children: <Widget>[
                    _miniBtn('标定', () => _calibrate(capture),
                        enabled: !_busy),
                    if (isReference)
                      _miniBtn('换图', _replaceReference, enabled: !_busy)
                    else
                      _miniBtn(
                        capture.isCalibrated ? '对比' : '对比（先标定）',
                        () => _compareOne(capture),
                        enabled: capture.isCalibrated && !_busy,
                      ),
                    _miniBtn('删除', () => _confirmDelete(capture),
                        color: AppColors.danger, enabled: !_busy),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniBtn(String label, VoidCallback onTap,
      {Color? color, bool enabled = true}) {
    return TextButton(
      onPressed: enabled ? onTap : null,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: color,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _thumbPlaceholder() {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: AppColors.line(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.image_outlined,
          size: 28, color: AppColors.textHint),
    );
  }

  Future<void> _addTarget() async {
    if (_busy) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(ctx);
                _pick('target', camera: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册上传'),
              onTap: () {
                Navigator.pop(ctx);
                _pick('target', camera: false);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 结果区：可切换目标，并排大图 + ΔE，点图全屏。
  Widget _resultSection(SessionDetail detail) {
    final Capture? reference = detail.reference;
    final List<Capture> comparedTargets = detail.targets
        .where((Capture t) => detail.comparisons.containsKey(t.id))
        .toList();
    if (reference == null || comparedTargets.isEmpty) {
      return const SizedBox.shrink();
    }

    // 只算「这一帧该显示第几个」，不在 build 里改 state
    final int index = _resultIndex.clamp(0, comparedTargets.length - 1);
    final Capture target = comparedTargets[index];
    final Comparison comparison = detail.comparisons[target.id]!;
    // 左边永远是家里那张**原图**，不经过任何处理
    final String refPath = reference.imagePath;
    final String outPath = comparison.processedPath;
    final String rightPath = _showBefore ? target.imagePath : outPath;
    final bool multi = comparedTargets.length > 1;
    final String hint = _showBefore
        ? '左：家里（已标定）　右：厂里（原始，没拉平）'
        : '左：家里　右：厂里（已拉平）　·　改善 ' +
            (comparison.improvement * 100).toStringAsFixed(0) + '%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Text('对比结果',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const Spacer(),
            if (multi) ...<Widget>[
              IconButton(
                onPressed: index == 0
                    ? null
                    : () => setState(() {
                          _resultIndex = index - 1;
                          _showBefore = false;
                        }),
                icon: const Icon(Icons.chevron_left, size: 20),
                visualDensity: VisualDensity.compact,
                tooltip: '上一个目标',
              ),
              Text((index + 1).toString() + '/' + comparedTargets.length.toString(),
                  style: const TextStyle(fontSize: 12)),
              IconButton(
                onPressed: index == comparedTargets.length - 1
                    ? null
                    : () => setState(() {
                          _resultIndex = index + 1;
                          _showBefore = false;
                        }),
                icon: const Icon(Icons.chevron_right, size: 20),
                visualDensity: VisualDensity.compact,
                tooltip: '下一个目标',
              ),
            ],
          ],
        ),
        if (multi)
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: comparedTargets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (BuildContext context, int i) {
                final Capture t = comparedTargets[i];
                final Comparison c = detail.comparisons[t.id]!;
                return ChoiceChip(
                  label: Text(t.shortId + ' · ΔE ' + c.deltaE.toString(),
                      style: const TextStyle(fontSize: 11)),
                  selected: i == index,
                  onSelected: (_) => setState(() {
                    _resultIndex = i;
                    _showBefore = false;
                  }),
                  visualDensity: VisualDensity.compact,
                );
              },
            ),
          ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => _openViewer(
            <String>[refPath, rightPath],
            <String>[
              '参照（家里）',
              _showBefore
                  ? '目标 ' + target.shortId + '（原始）'
                  : '目标 ' + target.shortId + '（校正后）'
            ],
            0,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: SizedBox(
              height: 240,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Image.file(File(refPath),
                        cacheWidth: 720, fit: BoxFit.cover),
                  ),
                  Container(width: 2, color: AppColors.line(context)),
                  Expanded(
                    child: Image.file(File(rightPath),
                        cacheWidth: 720, fit: BoxFit.cover),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: GestureDetector(
                onTapDown: (_) => setState(() => _showBefore = true),
                onTapUp: (_) => setState(() => _showBefore = false),
                onTapCancel: () => setState(() => _showBefore = false),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  decoration: BoxDecoration(
                    color: _showBefore
                        ? AppColors.warning.withValues(alpha: 0.12)
                        : AppColors.card(context),
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    border: Border.all(
                        color: _showBefore
                            ? AppColors.warning
                            : AppColors.line(context)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(
                        _showBefore ? Icons.visibility_off : Icons.visibility,
                        size: 16,
                        color: _showBefore
                            ? AppColors.warning
                            : AppColors.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _showBefore ? '正在看原图…' : '按住看原图',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _showBefore
                                ? AppColors.warning
                                : AppColors.text),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text('ΔE ' + comparison.deltaE.toString(),
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.success)),
                if (comparison.hasErrorFloor)
                  Text('可信 ' + comparison.trustworthy.toStringAsFixed(2),
                      style: TextStyle(
                          fontSize: 11, color: AppColors.sub(context))),
                Text('校正前 ' + comparison.deltaEBefore.toString(),
                    style: TextStyle(
                        fontSize: 11, color: AppColors.sub(context))),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(hint,
            style: const TextStyle(
                fontSize: 11, color: AppColors.textSecondary)),
        if (comparison.hasErrorFloor)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              comparison.errorFloor > 5
                  ? '误差下限 ΔE ' +
                      comparison.errorFloor.toStringAsFixed(1) +
                      '（偏大：两块已知物对不上，本次对比不可信，建议重拍）'
                  : '误差下限 ΔE ' +
                      comparison.errorFloor.toStringAsFixed(1) +
                      '　·　本次 ΔE 里约有这么多是噪声',
              style: TextStyle(
                  fontSize: 11,
                  color: comparison.errorFloor > 5
                      ? AppColors.danger
                      : AppColors.sub(context)),
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _openViewer(
                  <String>[refPath, outPath],
                  <String>['参照（家里）', '目标 ' + target.shortId + '（校正后）'],
                  0,
                ),
                icon: const Icon(Icons.fullscreen, size: 18),
                label: const Text('全屏看'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('保存对比图'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
