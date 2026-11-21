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
import '../../core/ccm.dart';
import '../../core/db.dart';
import '../../core/image_pipeline.dart';
import '../../core/models.dart';
import '../../core/report_renderer.dart';
import '../../core/storage.dart';
import '../capture/capture_page.dart';
import '../capture/calibrate_page.dart';
import '../viewer/photo_view_page.dart';
import 'comparison_detail_page.dart';

/// 会话详情：一个参照（家里，基准）+ 多个目标（厂里 / 别的环境）。
///
/// 四条约定：
/// * 图像重活全部走 image_pipeline（后台 isolate），UI 线程不解码大图；
/// * 家里那张**永远是原图**，只当基准；只把工地那张拉到家里的光线；
/// * 重新标定 / 换参照图会让旧对比失效，**并连带删掉旧成图文件**；
/// * 任何耗时操作期间，行内按钮一起禁用。
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
  String? _loadError;
  int _resultIndex = 0;
  bool _showBefore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final SessionDetail? detail =
          await AppDb.instance.detail(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.toString());
    }
  }

  // ------------------------------------------------------------ 采集

  Future<void> _pick(String role, {required bool camera}) async {
    if (_busy) return;
    if (camera) {
      final CaptureOutcome? outcome =
          await Navigator.of(context).push<CaptureOutcome>(
        MaterialPageRoute<CaptureOutcome>(
          builder: (_) => CapturePage(role: role, sessionId: widget.sessionId),
        ),
      );
      if (outcome == null || !mounted) return;
      await _saveCapture(role, outcome.path, 'camera', outcome.usedTorch);
      return;
    }
    final XFile? picked =
        await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2400);
    if (picked == null || !mounted) return;
    await _saveCapture(role, picked.path, 'upload', false);
  }

  Future<void> _saveCapture(
      String role, String sourcePath, String source, bool usedTorch) async {
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
      usedTorch: usedTorch,
      createdAt: DateTime.now(),
    ));
    await _load();
    if (!mounted) return;
    await _askLocation(id);
  }

  /// 给这张图打个「光」的标签：同一块样品换几个光源拍，才能看出是不是同色异谱。
  Future<void> _askLocation(String captureId) async {
    const List<String> presets = <String>[
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
            ...presets.map((String value) => ListTile(
                  dense: true,
                  title: Text(value, style: const TextStyle(fontSize: 14)),
                  onTap: () => Navigator.pop(ctx, value),
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

  /// 换参照图：**先拍新的，再问要不要替换**（以前是先删后拍，中途退出参照就没了）。
  Future<void> _replaceReference() async {
    if (_busy) return;
    final CaptureOutcome? outcome =
        await Navigator.of(context).push<CaptureOutcome>(
      MaterialPageRoute<CaptureOutcome>(
        builder: (_) =>
            CapturePage(role: 'reference', sessionId: widget.sessionId),
      ),
    );
    if (outcome == null || !mounted) return;

    final Capture? old = _detail?.reference;
    if (old != null) {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('替换参照图？'),
          content: const Text('旧参照图、以及所有基于它的对比结果都会被删掉。'),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('保留旧的')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (ok != true) {
        await _deleteQuietly(outcome.path);
        return;
      }
      await _deleteCaptureAndFiles(old);
    }
    if (!mounted) return;
    await _saveCapture('reference', outcome.path, 'camera', outcome.usedTorch);
  }

  /// 删一张图：DB 会回传所有相关成图路径，文件和行一起清干净。
  Future<void> _deleteCaptureAndFiles(Capture capture) async {
    final List<String> processed =
        await AppDb.instance.deleteCapture(capture.id, widget.sessionId);
    await _deleteQuietly(capture.imagePath);
    for (final String path in processed) {
      await _deleteQuietly(path);
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
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
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
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
      // 只记白点与已知物这两个数值，**不生成、不改写任何照片**。
      await AppDb.instance.updateCaptureCalibration(
        capture.id,
        whiteR: white.r.round(),
        whiteG: white.g.round(),
        whiteB: white.b.round(),
        checkR: checker?.r.round(),
        checkG: checker?.g.round(),
        checkB: checker?.b.round(),
      );
      // 白点变了，旧结果必须失效，成图文件一起删
      final List<String> stale = capture.isReference
          ? await AppDb.instance.invalidateComparisons(widget.sessionId)
          : await AppDb.instance
              .invalidateComparisonOf(widget.sessionId, capture.id);
      for (final String path in stale) {
        await _deleteQuietly(path);
      }
      _resultIndex = 0;
      await _load();
      if (mounted) {
        showSnack(
            context, '已记录白点 ' + white.toString() + '（照片不会被改动）');
      }
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

  /// 一批目标一次算完：参照图只解码一遍，结果一起回传。
  ///
  /// 如果用户做过 24 色卡校正，这里会带上 CCM（先校相机色彩，再拉白点）。
  Future<int> _runBatch(Capture reference, List<Capture> targets) async {
    final CameraCcm? ccm = await CameraProfile.load();
    final List<CompareTask> tasks = <CompareTask>[
      for (final Capture t in targets)
        CompareTask(
          targetId: t.id,
          path: t.imagePath,
          whiteR: t.whiteR!,
          whiteG: t.whiteG!,
          whiteB: t.whiteB!,
          checkR: t.checkR,
          checkG: t.checkG,
          checkB: t.checkB,
        ),
    ];
    final List<CompareOutcome> outcomes = await compareMany(
      referencePath: reference.imagePath,
      referenceR: reference.whiteR!,
      referenceG: reference.whiteG!,
      referenceB: reference.whiteB!,
      referenceCheckR: reference.checkR,
      referenceCheckG: reference.checkG,
      referenceCheckB: reference.checkB,
      ccm: ccm == null
          ? null
          : <double>[...ccm.matrix, ...ccm.offset],
      tasks: tasks,
    );

    final Directory dir = await getApplicationDocumentsDirectory();
    int done = 0;
    for (final CompareOutcome outcome in outcomes) {
      if (!outcome.ok || outcome.jpeg == null) continue;
      final String processedPath = p.join(dir.path, 'captures',
          widget.sessionId, outcome.targetId + '_matched.jpg');
      await File(processedPath).writeAsBytes(outcome.jpeg!);
      await AppDb.instance.upsertComparison(Comparison(
        id: const Uuid().v4(),
        sessionId: widget.sessionId,
        referenceCaptureId: reference.id,
        targetCaptureId: outcome.targetId,
        processedPath: processedPath,
        deltaE: double.parse(outcome.deltaE.toStringAsFixed(2)),
        deltaEBefore: double.parse(outcome.deltaEBefore.toStringAsFixed(2)),
        errorFloor: double.parse(outcome.errorFloor.toStringAsFixed(2)),
        createdAt: DateTime.now(),
      ));
      done++;
    }
    return done;
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
      await _runBatch(reference, <Capture>[target]);
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
        .where((Capture t) =>
            t.isCalibrated && !detail.comparisons.containsKey(t.id))
        .toList();
    if (pending.isEmpty) {
      showSnack(context, '没有待对比的目标（或都没标定）');
      return;
    }
    setState(() {
      _busy = true;
      _progress = '处理 ' + pending.length.toString() + ' 个目标…';
    });
    try {
      final int done = await _runBatch(reference, pending);
      await _load();
      if (!mounted) return;
      showSnack(
        context,
        done == pending.length
            ? '已对比 ' + done.toString() + ' 个目标'
            : '完成 ' +
                done.toString() +
                ' 个，失败 ' +
                (pending.length - done).toString() +
                ' 个',
        error: done != pending.length,
      );
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

  // ------------------------------------------------------------ 详情 / 导出

  void _openViewer(List<String> paths, List<String> captions, int index) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PhotoViewPage(
        items: paths,
        captions: captions,
        initialIndex: index,
      ),
    ));
  }

  Future<void> _openDetail(Capture target) async {
    final SessionDetail? detail = _detail;
    final Capture? reference = detail?.reference;
    final Comparison? comparison = detail?.comparisons[target.id];
    if (detail == null || reference == null || comparison == null) return;

    final bool? deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ComparisonDetailPage(
          sessionName: detail.session.name,
          reference: reference,
          target: target,
          comparison: comparison,
        ),
      ),
    );
    if (deleted == true) {
      await AppDb.instance.deleteComparison(widget.sessionId, target.id);
      await _deleteQuietly(comparison.processedPath);
      await _load();
      if (mounted) showSnack(context, '已删除这条对比');
    }
  }

  Future<void> _exportAll() async {
    final SessionDetail? detail = _detail;
    if (detail == null) return;
    final Capture? reference = detail.reference;
    if (reference == null || detail.comparisons.isEmpty) return;

    final List<ReportRow> rows = <ReportRow>[];
    int index = 0;
    for (final Capture target in detail.targets) {
      final Comparison? c = detail.comparisons[target.id];
      if (c == null) continue;
      index++;
      rows.add(_rowFor(detail, reference, target, c, index));
    }
    await _renderAndSave(detail.session.name, detail.session.note, rows);
  }

  Future<void> _exportOne(Capture target) async {
    final SessionDetail? detail = _detail;
    final Capture? reference = detail?.reference;
    final Comparison? c = detail?.comparisons[target.id];
    if (detail == null || reference == null || c == null) return;
    await _renderAndSave(
      detail.session.name,
      detail.session.note,
      <ReportRow>[_rowFor(detail, reference, target, c, 1, single: true)],
    );
  }

  ReportRow _rowFor(SessionDetail detail, Capture reference, Capture target,
      Comparison c, int index,
      {bool single = false}) {
    return ReportRow(
      label: single
          ? '目标 ' + target.shortId
          : '第 ' + index.toString() + ' 组 · 目标 ' + target.shortId,
      referencePath: reference.imagePath,
      beforePath: target.imagePath,
      afterPath: c.processedPath,
      deltaE: c.deltaE,
      deltaEBefore: c.deltaEBefore,
      errorFloor: c.errorFloor,
      trustworthy: c.trustworthy,
      location: target.location,
      createdAt: c.createdAt,
    );
  }

  Future<void> _renderAndSave(
      String sessionName, String sessionNote, List<ReportRow> rows) async {
    if (rows.isEmpty) {
      showSnack(context, '没有可导出的对比', error: true);
      return;
    }
    setState(() {
      _busy = true;
      _progress = '生成报告…';
    });
    try {
      final Uint8List png = await renderReportPng(
        sessionName: sessionName,
        sessionNote: sessionNote,
        rows: rows,
      );
      final Directory dir = await exportDir();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final String safeName =
          sessionName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final String fileName = safeName + '_' + stamp + '.png';
      final File file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(png);
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
              onPressed: _busy ? null : _exportAll,
              icon: const Icon(Icons.save_alt),
              tooltip: '导出整份报告',
            ),
        ],
      ),
      body: _loadError != null
          ? _errorView()
          : detail == null
              ? const Center(child: CircularProgressIndicator())
              : _content(detail),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
            const SizedBox(height: 12),
            const Text('读取这个会话失败',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_loadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () {
                setState(() => _loadError = null);
                _load();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(SessionDetail detail) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xl),
      children: <Widget>[
        _nextStepBanner(detail),
        const SizedBox(height: AppSpacing.sm),
        _sectionTitle('参照（家里，基准）'),
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
          _emptyRow('还没有目标图，点「添加」拍厂里的样品。白纸露一个角，最好再放一块已知物（灰卡/样板）用来自检。')
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
    );
  }

  /// 顶部引导：永远告诉用户「下一步该做什么」，而不是让他自己找。
  Widget _nextStepBanner(SessionDetail detail) {
    final Capture? reference = detail.reference;
    final int uncalibrated =
        detail.targets.where((Capture t) => !t.isCalibrated).length;
    final int calibratedTargets =
        detail.targets.where((Capture t) => t.isCalibrated).length;
    final int pending = detail.pendingCount;

    late final String text;
    late final IconData icon;
    late final Color color;
    if (reference == null) {
      text = '第一步：拍一张家里的参照图（把白纸露一个角）';
      icon = Icons.home_outlined;
      color = AppColors.warning;
    } else if (!reference.isCalibrated) {
      text = '参照图还没标定 · 点下面的「标定」框住那块白纸';
      icon = Icons.center_focus_strong_outlined;
      color = AppColors.warning;
    } else if (detail.targets.isEmpty) {
      text = '第二步：拍工地 / 门店的样品';
      icon = Icons.add_a_photo_outlined;
      color = AppColors.primary;
    } else if (uncalibrated > 0) {
      text = '有 ' + uncalibrated.toString() + ' 张目标图还没标定';
      icon = Icons.center_focus_strong_outlined;
      color = AppColors.warning;
    } else if (pending > 0) {
      text = '有 ' +
          pending.toString() +
          ' 组还没对比 · 点下面的「全部对比」';
      icon = Icons.compare_arrows;
      color = AppColors.primary;
    } else {
      text = '准备就绪：已标定 ' +
          calibratedTargets.toString() +
          ' 张目标、完成 ' +
          detail.comparedCount.toString() +
          ' 组对比';
      icon = Icons.check_circle_outline;
      color = AppColors.success;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ),
          if (detail.targets.isNotEmpty && uncalibrated == 0 && pending > 0)
            TextButton(
              onPressed: _busy ? null : _compareAll,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('去对比', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  /// 一小块状态徽章：绿=已标定，橙=未标定，蓝=已对比。
  Widget _statusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
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
          style: const TextStyle(
              fontSize: 12, height: 1.6, color: AppColors.textSecondary)),
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
          // 左侧竖条：没标定就是橙色，一眼能扫出来
          Container(
            width: 3,
            height: 84,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: capture.isCalibrated
                  ? AppColors.success
                  : AppColors.warning,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          GestureDetector(
            onLongPress: () => _captureActions(capture, title),
            onTap: () => _openViewer(
              <String>[capture.imagePath],
              <String>[title + '（原图）'],
              0,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(capture.imagePath),
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
                    Flexible(
                      child: Text(title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 6),
                    if (comparison != null)
                      Text('ΔE ' + comparison.deltaE.toString(),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.success)),
                    const SizedBox(width: 4),
                    _statusChip(
                      comparison != null
                          ? '已对比'
                          : (capture.isCalibrated ? '已标定' : '未标定'),
                      comparison != null
                          ? AppColors.primary
                          : (capture.isCalibrated
                              ? AppColors.success
                              : AppColors.warning),
                    ),
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
                          (capture.location.isEmpty
                              ? ''
                              : '　·　' + capture.location) +
                          (capture.usedTorch ? '　·　开了补光' : '')
                      : '未标定',
                  style: TextStyle(
                      fontSize: 11,
                      color: capture.isCalibrated
                          ? AppColors.sub(context)
                          : AppColors.warning),
                ),
                Wrap(
                  children: <Widget>[
                    if (!capture.isCalibrated)
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : () => _calibrate(capture),
                        icon: const Icon(Icons.center_focus_strong_outlined,
                            size: 16),
                        label: const Text('现在标定',
                            style: TextStyle(fontSize: 12)),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                    else
                      _miniBtn('重新标定', () => _calibrate(capture),
                          enabled: !_busy),
                    if (isReference)
                      _miniBtn('换图', _replaceReference, enabled: !_busy)
                    else ...<Widget>[
                      _miniBtn(
                        capture.isCalibrated ? '对比' : '对比（先标定）',
                        () => _compareOne(capture),
                        enabled: capture.isCalibrated && !_busy,
                      ),
                      if (comparison != null)
                        _miniBtn('详情', () => _openDetail(capture),
                            enabled: !_busy),
                    ],
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

  /// 长按缩略图：把这张原图存相册 / 分享 / 复制路径。
  Future<void> _captureActions(Capture capture, String title) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title + ' · 原图',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.download_outlined),
              title: const Text('保存原图到相册', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, 'save'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享原图', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link),
              title: const Text('复制文件路径', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, 'path'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.fullscreen),
              title: const Text('全屏看', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, 'view'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'save':
        final bool ok = await saveToGallery(capture.imagePath);
        if (!mounted) return;
        showSnack(context, ok ? '已保存到相册（原图）' : '保存失败（权限或空间）',
            error: !ok);
        break;
      case 'share':
        try {
          await SharePlus.instance.share(
              ShareParams(files: <XFile>[XFile(capture.imagePath)]));
        } catch (error) {
          if (!mounted) return;
          showSnack(context, '分享失败：' + error.toString(), error: true);
        }
        break;
      case 'path':
        await Clipboard.setData(ClipboardData(text: capture.imagePath));
        if (!mounted) return;
        showSnack(context, '路径已复制');
        break;
      case 'view':
        _openViewer(<String>[capture.imagePath], <String>[title + '（原图）'], 0);
        break;
    }
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

    final int index = _resultIndex.clamp(0, comparedTargets.length - 1);
    final Capture target = comparedTargets[index];
    final Comparison comparison = detail.comparisons[target.id]!;
    final String rightPath =
        _showBefore ? target.imagePath : comparison.processedPath;
    final bool multi = comparedTargets.length > 1;
    final String hint = _showBefore
        ? '左：家里（基准）　右：工地原始画面'
        : '左：家里（基准）　右：工地拉到家里光线后　·　改善 ' +
            (comparison.improvement * 100).toStringAsFixed(0) +
            '%';

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
              Text((index + 1).toString() +
                  '/' +
                  comparedTargets.length.toString(),
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
            <String>[reference.imagePath, rightPath],
            <String>[
              '家里（基准）',
              _showBefore
                  ? '目标 ' + target.shortId + '（原始）'
                  : '目标 ' + target.shortId + '（拉到家里光线后）'
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
                    child: Image.file(File(reference.imagePath),
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
                  padding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 12),
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
                        _showBefore
                            ? Icons.visibility_off
                            : Icons.visibility,
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
                onPressed: _busy ? null : () => _openDetail(target),
                icon: const Icon(Icons.info_outline, size: 18),
                label: const Text('详情'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _exportOne(target),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('导出这组'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy ? null : _exportAll,
            icon: const Icon(Icons.save_alt, size: 18),
            label: const Text('导出整份报告'),
          ),
        ),
      ],
    );
  }
}
