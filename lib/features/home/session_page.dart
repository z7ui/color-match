import 'dart:io';

import 'package:flutter/material.dart';
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
import '../capture/capture_page.dart';
import '../capture/calibrate_page.dart';

/// 会话详情：一个参照（家里）+ 多个目标（厂里 / 其他环境）。
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

  /// 对单个目标做对比。
  Future<void> _compareOne(Capture target) async {
    final SessionDetail? detail = _detail;
    final Capture? reference = detail?.reference;
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

  Future<Comparison> _runCompare(Capture reference, Capture target) async {
    final img.Image refImage = img.decodeImage(
        await File(reference.calibratedPath ?? reference.imagePath).readAsBytes())!;
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

  /// 所有未对比的目标一次跑完。
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
      } catch (_) {
        // 单个失败不影响其他
      }
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

  /// 导出：参照 + 每个目标（校正前/后）拼成一张长图。
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
        final img.Image before =
            downscale(img.decodeImage(await File(target.imagePath).readAsBytes())!,
                maxSide: 1000);
        final img.Image after = downscale(
            img.decodeImage(await File(comparison.processedPath).readAsBytes())!,
            maxSide: 1000);
        rows.add(buildRow(
          reference: ref,
          before: before,
          after: after,
          label: '#${target.id.substring(0, 4)}  ΔE ${comparison.deltaE}',
        ));
      }
      if (rows.isEmpty) {
        if (mounted) showSnack(context, '没有可导出的对比', error: true);
        return;
      }

      final img.Image report = buildVerticalReport(rows);
      final Directory dir = await getApplicationDocumentsDirectory();
      final String path = p.join(
          dir.path, 'captures', widget.sessionId, 'report_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(path).writeAsBytes(img.encodeJpg(report, quality: 92));

      await SharePlus.instance.share(ShareParams(
        files: <XFile>[XFile(path)],
        text: '${detail.session.name} · ${detail.comparisons.length} 个目标',
      ));
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
              icon: const Icon(Icons.ios_share),
              tooltip: '导出对比图',
            ),
        ],
      ),
      body: detail == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: <Widget>[
                _captureCard(
                    'reference', '参照（家里）', '默认以这张为基准', detail.reference),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: <Widget>[
                    const Text('目标',
                        style:
                            TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text('${detail.targets.length} 个',
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSecondary)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => showModalBottomSheet<void>(
                                context: context,
                                builder: (_) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      ListTile(
                                        leading: const Icon(Icons.camera_alt_outlined),
                                        title: const Text('拍照'),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          _pick('target', camera: true);
                                        },
                                      ),
                                      ListTile(
                                        leading:
                                            const Icon(Icons.photo_library_outlined),
                                        title: const Text('从相册上传'),
                                        onTap: () {
                                          Navigator.of(context).pop();
                                          _pick('target', camera: false);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                if (detail.targets.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    decoration: BoxDecoration(
                      color: AppColors.card(context),
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: AppColors.line(context)),
                    ),
                    child: const Center(
                      child: Text('还没有目标图，点右上角「添加」',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ),
                  )
                else
                  ...detail.targets.map((Capture t) => _targetCard(t)),
                const SizedBox(height: AppSpacing.lg),
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
              ],
            ),
    );
  }

  Widget _captureCard(
      String role, String title, String subtitle, Capture? capture) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (capture != null)
                  IconButton(
                    onPressed: () => _calibrate(capture),
                    icon: const Icon(Icons.crop_free, size: 20),
                    tooltip: '标定（框选白纸）',
                  ),
              ],
            ),
            Text(subtitle,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.md),
            capture == null
                ? Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _pick(role, camera: true),
                          icon: const Icon(Icons.camera_alt_outlined, size: 18),
                          label: const Text('拍照'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _pick(role, camera: false),
                          icon: const Icon(Icons.photo_library_outlined, size: 18),
                          label: const Text('上传'),
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                        child: Image.file(
                            File(capture.calibratedPath ?? capture.imagePath),
                            height: 180,
                            width: double.infinity,
                            fit: BoxFit.cover),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: <Widget>[
                          Icon(
                            capture.whiteR == null
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                            size: 16,
                            color: capture.whiteR == null
                                ? AppColors.warning
                                : AppColors.success,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            capture.whiteR == null
                                ? '未标定（点右上角框选白纸）'
                                : '白点 (${capture.whiteR}, ${capture.whiteG}, ${capture.whiteB})',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textSecondary),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _pick(role, camera: false),
                            child: const Text('换图'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  Widget _targetCard(Capture target) {
    final Comparison? comparison = _detail?.comparisons[target.id];
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('#${target.id.substring(0, 4)}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (comparison != null)
                  Text('ΔE ${comparison.deltaE}',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.success)),
                const Spacer(),
                IconButton(
                  onPressed: () => _calibrate(target),
                  icon: const Icon(Icons.crop_free, size: 20),
                ),
                IconButton(
                  onPressed: _busy ? null : () => _compareOne(target),
                  icon: const Icon(Icons.compare, size: 20),
                ),
              ],
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: Image.file(
                File(comparison?.processedPath ??
                    target.calibratedPath ??
                    target.imagePath),
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              target.whiteR == null
                  ? '未标定'
                  : '白点 (${target.whiteR}, ${target.whiteG}, ${target.whiteB})'
                      '${comparison == null ? '' : ' · 已校正'}',
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
