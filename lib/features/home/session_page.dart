import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_theme.dart';
import '../../core/calibration.dart';
import '../../core/compare.dart';
import '../../core/db.dart';
import '../../core/models.dart';
import '../../core/storage.dart';
import '../capture/capture_page.dart';
import '../capture/calibrate_page.dart';
import '../viewer/photo_view_page.dart';

/// 会话详情：一个参照（家里）+ 多个目标（厂里 / 其他环境）。
/// 布局按「一行一张图」做，避免把照片挤成小方块。
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

  /// 结果区当前看的是第几个目标（多目标时切换）
  int _resultIndex = 0;

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
    if (camera) {
      final String? path = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => CapturePage(role: role, sessionId: widget.sessionId),
        ),
      );
      if (path == null) return;
      await _saveCapture(role, path, 'camera');
      return;
    }
    final XFile? picked =
        await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2400);
    if (picked == null) return;
    await _saveCapture(role, picked.path, 'upload');
  }

  Future<void> _saveCapture(String role, String sourcePath, String source) async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String id = const Uuid().v4();
    final String ext =
        p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final String dest =
        p.join(dir.path, 'captures', widget.sessionId, '${id}_$role$ext');
    await File(dest).create(recursive: true);
    await File(sourcePath).copy(dest);

    await AppDb.instance.insertCapture(Capture(
      id: id,
      sessionId: widget.sessionId,
      role: role,
      imagePath: dest,
      source: source,
      createdAt: DateTime.now(),
    ));
    await _load();
  }

  Future<void> _confirmDelete(Capture capture) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除这张图？'),
        content: Text(capture.isReference
            ? '参照图删掉后，目标图就没有基准了。'
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

    await AppDb.instance.deleteCapture(capture.id, widget.sessionId);
    for (final String? path in <String?>[
      capture.imagePath,
      capture.calibratedPath
    ]) {
      if (path != null) {
        try {
          final File f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    await _load();
    if (mounted) showSnack(context, '已删除');
  }

  // ------------------------------------------------------------ 标定

  Future<void> _calibrate(Capture capture) async {
    final WhitePoint? white = await Navigator.of(context).push<WhitePoint>(
      MaterialPageRoute<WhitePoint>(
        builder: (_) => CalibratePage(imagePath: capture.imagePath),
      ),
    );
    if (white == null) return;

    final img.Image decoded =
        img.decodeImage(await File(capture.imagePath).readAsBytes())!;
    final img.Image fixed =
        applyWhiteBalance(downscale(decoded, maxSide: 1400), white: white);

    final Directory dir = await getApplicationDocumentsDirectory();
    final String path = p.join(
        dir.path, 'captures', widget.sessionId, '${capture.id}_calibrated.jpg');
    await File(path).writeAsBytes(img.encodeJpg(fixed, quality: 92));

    await AppDb.instance.updateCaptureWhite(Capture(
      id: capture.id,
      sessionId: capture.sessionId,
      role: capture.role,
      imagePath: capture.imagePath,
      source: capture.source,
      location: capture.location,
      calibratedPath: path,
      whiteR: white.r.round(),
      whiteG: white.g.round(),
      whiteB: white.b.round(),
      calibrationMethod: 'white_patch',
      createdAt: capture.createdAt,
    ));
    await _load();
    if (mounted) showSnack(context, '已标定：白点 $white → 255');
  }

  // ------------------------------------------------------------ 对比

  Future<Comparison> _runCompare(Capture reference, Capture target) async {
    final img.Image refImage = img.decodeImage(
        await File(reference.calibratedPath ?? reference.imagePath)
            .readAsBytes())!;
    final img.Image targetImage =
        img.decodeImage(await File(target.imagePath).readAsBytes())!;

    final CompareResult result = compareToReference(
      reference: refImage,
      target: downscale(targetImage, maxSide: 1400),
      referenceWhite: WhitePoint(reference.whiteR!.toDouble(),
          reference.whiteG!.toDouble(), reference.whiteB!.toDouble()),
      targetWhite: WhitePoint(target.whiteR!.toDouble(),
          target.whiteG!.toDouble(), target.whiteB!.toDouble()),
    );

    final Directory dir = await getApplicationDocumentsDirectory();
    final String processedPath = p.join(
        dir.path, 'captures', widget.sessionId, '${target.id}_matched.jpg');
    await File(processedPath)
        .writeAsBytes(img.encodeJpg(result.processed, quality: 92));

    final Comparison comparison = Comparison(
      id: const Uuid().v4(),
      sessionId: widget.sessionId,
      referenceCaptureId: reference.id,
      targetCaptureId: target.id,
      processedPath: processedPath,
      deltaE: double.parse(result.deltaEAfter.toStringAsFixed(2)),
      createdAt: DateTime.now(),
      note: '校正前 ΔE ${result.deltaEBefore.toStringAsFixed(2)}',
    );
    await AppDb.instance.upsertComparison(comparison);
    return comparison;
  }

  Future<void> _compareOne(Capture target) async {
    final Capture? reference = _detail?.reference;
    if (reference == null) {
      showSnack(context, '先拍/传一张参照图', error: true);
      return;
    }
    if (reference.whiteR == null || target.whiteR == null) {
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
      if (mounted) showSnack(context, '对比失败：$error', error: true);
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
    final SessionDetail? detail = _detail;
    final Capture? reference = detail?.reference;
    if (detail == null || reference == null) return;
    if (reference.whiteR == null) {
      showSnack(context, '参照图还没标定', error: true);
      return;
    }
    final List<Capture> pending = detail.targets
        .where((Capture t) =>
            t.whiteR != null && !detail.comparisons.containsKey(t.id))
        .toList();
    if (pending.isEmpty) {
      showSnack(context, '没有待对比的目标（或都没标定）');
      return;
    }
    setState(() {
      _busy = true;
      _progress = '0/${pending.length}';
    });
    int done = 0;
    for (final Capture target in pending) {
      try {
        await _runCompare(reference, target);
      } catch (_) {}
      done++;
      if (mounted) setState(() => _progress = '$done/${pending.length}');
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
    });
    showSnack(context, '已对比 $done 个目标');
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

  /// 保存到本地文件夹，并显示路径（可复制、可分享）。
  Future<void> _export() async {
    final SessionDetail? detail = _detail;
    final Capture? reference = detail?.reference;
    if (detail == null || reference == null || detail.comparisons.isEmpty) return;

    setState(() {
      _busy = true;
      _progress = '生成报告…';
    });
    try {
      final img.Image ref = downscale(
          img.decodeImage(
              await File(reference.calibratedPath ?? reference.imagePath)
                  .readAsBytes())!,
          maxSide: 1000);

      final List<img.Image> rows = <img.Image>[];
      for (final Capture target in detail.targets) {
        final Comparison? comparison = detail.comparisons[target.id];
        if (comparison == null) continue;
        final img.Image before = downscale(
            img.decodeImage(await File(target.imagePath).readAsBytes())!,
            maxSide: 1000);
        final img.Image after = downscale(
            img.decodeImage(await File(comparison.processedPath).readAsBytes())!,
            maxSide: 1000);
        rows.add(buildRow(
          reference: ref,
          before: before,
          after: after,
          label:
              'target ${target.id.substring(0, 4)}  dE ${comparison.deltaE}',
        ));
      }
      if (rows.isEmpty) {
        if (mounted) showSnack(context, '没有可导出的对比', error: true);
        return;
      }

      final img.Image report = buildVerticalReport(rows);
      final Directory dir = await exportDir();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final String fileName =
          '${detail.session.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}_$stamp.jpg';
      final File file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(img.encodeJpg(report, quality: 92));

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('已保存到本地'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('文件:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(fileName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              const Text('目录:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
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
      if (mounted) showSnack(context, '导出失败：$error', error: true);
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
        context,
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
                    _sectionTitle('目标（${detail.targets.length}）'),
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
                        title: '目标 ${t.id.substring(0, 4)}',
                        comparison: detail.comparisons[t.id],
                      )),
                const SizedBox(height: AppSpacing.md),
                if (detail.targets.isNotEmpty)
                  FilledButton.icon(
                    onPressed: _busy ? null : _compareAll,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.compare),
                    label: Text(_busy
                        ? (_progress ?? '处理中…')
                        : '全部对比（${detail.targets.where((Capture t) => t.whiteR != null && !detail.comparisons.containsKey(t.id)).length} 个待处理）'),
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

  /// 一行：缩略图 + 信息 + 操作。不再用大卡片占满屏。
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
                  style:
                      TextStyle(fontSize: 12, color: AppColors.sub(context))),
            ),
            OutlinedButton.icon(
              onPressed: () => _pick(role, camera: true),
              icon: const Icon(Icons.camera_alt_outlined, size: 16),
              label: const Text('拍照'),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10)),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: () => _pick(role, camera: false),
              icon: const Icon(Icons.photo_library_outlined, size: 20),
              tooltip: '从相册选',
            ),
          ],
        ),
      );
    }

    final String shown = comparison?.processedPath ??
        capture.calibratedPath ??
        capture.imagePath;
    final bool calibrated = capture.whiteR != null;

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
                comparison != null ? '$title（校正后）' : title,
                '$title（原始）',
              ],
              0,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(shown),
                  width: 84, height: 84, fit: BoxFit.cover),
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
                      Text('ΔE ${comparison.deltaE}',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.success)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  calibrated
                      ? '白点 (${capture.whiteR}, ${capture.whiteG}, ${capture.whiteB})'
                      : '未标定',
                  style: TextStyle(
                      fontSize: 11,
                      color: calibrated
                          ? AppColors.sub(context)
                          : AppColors.warning),
                ),
                Wrap(
                  children: <Widget>[
                    _miniBtn('标定', () => _calibrate(capture)),
                    if (isReference)
                      _miniBtn('换图', () => _pick(role, camera: false))
                    else
                      _miniBtn(
                        calibrated ? '对比' : '对比（先标定）',
                        () => _compareOne(capture),
                        enabled: calibrated,
                      ),
                    _miniBtn('删除', () => _confirmDelete(capture),
                        color: AppColors.danger),
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

    // 删除目标后索引可能越界
    if (_resultIndex >= comparedTargets.length) _resultIndex = 0;
    final Capture target = comparedTargets[_resultIndex];
    final Comparison comparison = detail.comparisons[target.id]!;
    final String refPath = reference.calibratedPath ?? reference.imagePath;
    final String outPath = comparison.processedPath;
    final bool multi = comparedTargets.length > 1;

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
                onPressed: _resultIndex == 0
                    ? null
                    : () => setState(() => _resultIndex--),
                icon: const Icon(Icons.chevron_left, size: 20),
                visualDensity: VisualDensity.compact,
                tooltip: '上一个目标',
              ),
              Text('${_resultIndex + 1}/${comparedTargets.length}',
                  style: const TextStyle(fontSize: 12)),
              IconButton(
                onPressed: _resultIndex == comparedTargets.length - 1
                    ? null
                    : () => setState(() => _resultIndex++),
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
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (BuildContext context, int i) {
                final Capture t = comparedTargets[i];
                final Comparison c = detail.comparisons[t.id]!;
                return ChoiceChip(
                  label: Text('${t.id.substring(0, 4)} · ΔE ${c.deltaE}',
                      style: const TextStyle(fontSize: 11)),
                  selected: i == _resultIndex,
                  onSelected: (_) => setState(() => _resultIndex = i),
                  visualDensity: VisualDensity.compact,
                );
              },
            ),
          ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => _openViewer(
            <String>[refPath, outPath],
            <String>[
              '参照（家里）',
              '目标 ${target.id.substring(0, 4)}（校正后）'
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
                        fit: BoxFit.cover, alignment: Alignment.center),
                  ),
                  Container(width: 2, color: AppColors.line(context)),
                  Expanded(
                    child: Image.file(File(outPath),
                        fit: BoxFit.cover, alignment: Alignment.center),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            const Text('左：家里　右：厂里（已拉平）',
                style:
                    TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            const Spacer(),
            Text('ΔE ${comparison.deltaE}',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.success)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _openViewer(
                  <String>[refPath, outPath],
                  <String>[
                    '参照（家里）',
                    '目标 ${target.id.substring(0, 4)}（校正后）'
                  ],
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
