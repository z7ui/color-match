import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../core/app_theme.dart';
import '../../core/calibration.dart';
import '../../core/image_pipeline.dart';

/// 标定页：在照片上框选一块「应该是白色」的区域（白纸 / 灰卡）。
///
/// 交互：单指拖动移动选框，双指缩放调整大小；底部实时显示平均 RGB。
///
/// 两个实现要点：
/// * **不能同时用 onPanUpdate 和 onScaleUpdate** —— Flutter 会直接抛
///   「Having both a pan gesture recognizer and a scale gesture recognizer」，
///   debug 下必崩、release 下双指缩放失效。所以只用 scale，按 pointerCount 分流。
/// * 拖动过程中用降采样（stride=4）采样，松手后再精算，避免每帧扫一遍全像素。
class CalibratePage extends StatefulWidget {
  const CalibratePage({super.key, required this.imagePath});

  final String imagePath;

  @override
  State<CalibratePage> createState() => _CalibratePageState();
}

class _CalibratePageState extends State<CalibratePage> {
  img.Image? _preview;
  Uint8List? _previewBytes;
  WhitePoint? _white;
  double? _spread;
  String? _error;

  Rect _selection = const Rect.fromLTWH(0.35, 0.35, 0.3, 0.3);
  double _startWidth = 0.3;
  bool _dragging = false;
  Size _viewSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Uint8List bytes = await File(widget.imagePath).readAsBytes();
      // 解码 + EXIF 摆正 + 缩放到预览尺寸，全在 isolate 里做
      final Uint8List preview = await decodePreviewBytes(bytes);
      if (!mounted) return;
      final img.Image? decoded = img.decodeImage(preview);
      if (decoded == null) {
        setState(() => _error = '图片解析失败');
        return;
      }
      setState(() {
        _previewBytes = preview;
        _preview = decoded;
      });
      _sample();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '读取失败：$error');
    }
  }

  void _sample({int stride = 1}) {
    final img.Image? image = _preview;
    if (image == null) return;
    final int x = (_selection.left * image.width).round();
    final int y = (_selection.top * image.height).round();
    final int w = (_selection.width * image.width).round();
    final int h = (_selection.height * image.height).round();

    setState(() {
      _white = sampleAverage(image, x, y, w, h, stride: stride);
      _spread = luminanceSpread(image, x, y, w, h, stride: stride < 2 ? 2 : stride);
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startWidth = _selection.width;
    _dragging = true;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      if (details.pointerCount == 1) {
        final Size view = _viewSize;
        if (view.width > 0 && view.height > 0) {
          _selection = _selection.translate(
            details.focalPointDelta.dx / view.width,
            details.focalPointDelta.dy / view.height,
          );
        }
      } else {
        // 双指缩放：以起始宽度乘以手势比例（别用上一帧的值，会指数放大）
        final double next = (_startWidth * details.scale).clamp(0.05, 0.95);
        _selection = Rect.fromCenter(
          center: _selection.center,
          width: next,
          height: next,
        );
      }
      _clampSelection();
    });
    _sample(stride: 4);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _dragging = false;
    _sample();
  }

  @override
  Widget build(BuildContext context) {
    final img.Image? image = _preview;
    return Scaffold(
      appBar: buildAppBar('框选白纸'),
      body: image == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!,
                          style: const TextStyle(color: AppColors.danger)),
                    )
                  : const CircularProgressIndicator(),
            )
          : Column(
              children: <Widget>[
                Expanded(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      final Size box = _fit(
                        Size(image.width.toDouble(), image.height.toDouble()),
                        constraints.biggest,
                      );
                      _viewSize = box;
                      return Center(
                        child: GestureDetector(
                          onScaleStart: _onScaleStart,
                          onScaleUpdate: _onScaleUpdate,
                          onScaleEnd: _onScaleEnd,
                          child: SizedBox(
                            width: box.width,
                            height: box.height,
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                if (_previewBytes != null)
                                  Image.memory(_previewBytes!,
                                      gaplessPlayback: true,
                                      fit: BoxFit.fill),
                                CustomPaint(
                                  painter: _SelectionPainter(
                                    selection: _selection,
                                    dragging: _dragging,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                _bottomBar(),
              ],
            ),
    );
  }

  Widget _bottomBar() {
    final WhitePoint? white = _white;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      color: AppColors.page(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: white == null
                      ? AppColors.line(context)
                      : Color.fromARGB(
                          255,
                          white.r.round().clamp(0, 255),
                          white.g.round().clamp(0, 255),
                          white.b.round().clamp(0, 255),
                        ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.line(context)),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  white == null
                      ? '正在采样…'
                      : '平均色 $white　·　块内跨度 ${_spread?.toStringAsFixed(0) ?? '-'}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          if (white != null) ...<Widget>[
            const SizedBox(height: 6),
            _qualityHint(white),
          ],
          const SizedBox(height: 4),
          const Text(
            '框住画面里那块白（纸的一角就够），别框到瓷砖或阴影。单指拖动移动框，双指缩放调整大小。',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: white == null ? null : () => Navigator.of(context).pop(white),
              child: const Text('用这个白点'),
            ),
          ),
        ],
      ),
    );
  }

  /// 白纸质量自检：沿用 A4 灰阶靶的三条硬指标里能在这里判断的。
  Widget _qualityHint(WhitePoint white) {
    final List<String> issues = <String>[];
    if (white.luminance < 235) {
      issues.add('白参考偏低（${white.luminance.toStringAsFixed(0)}，应 ≥235）：光不够或相机欠曝');
    }
    if ((_spread ?? 0) > 15) {
      issues.add('块内不匀（跨度 ${_spread!.toStringAsFixed(0)}，应 ≤15）：框里有反光或阴影');
    }
    if (white.chromaSpread > 18) {
      issues.add('这块白偏色（通道差 ${white.chromaSpread.toStringAsFixed(0)}）：可能框到了带颜色的纸');
    }
    if (issues.isEmpty) {
      return const Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline, size: 16, color: AppColors.success),
          SizedBox(width: 4),
          Text('这块白纸可以用来标定',
              style: TextStyle(fontSize: 12, color: AppColors.success)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: issues
          .map((String issue) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.warning_amber_rounded,
                        size: 16, color: AppColors.warning),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(issue,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.warning)),
                    ),
                  ],
                ),
              ))
          .toList(),
    );
  }

  void _clampSelection() {
    final double w = _selection.width.clamp(0.05, 0.95);
    final double h = _selection.height.clamp(0.05, 0.95);
    final double left = _selection.left.clamp(0.0, 1 - w);
    final double top = _selection.top.clamp(0.0, 1 - h);
    _selection = Rect.fromLTWH(left, top, w, h);
  }

  Size _fit(Size content, Size box) {
    final double ratio = content.width / content.height;
    double w = box.width;
    double h = w / ratio;
    if (h > box.height) {
      h = box.height;
      w = h * ratio;
    }
    return Size(w, h);
  }
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter({required this.selection, required this.dragging});

  final Rect selection;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Rect.fromLTWH(
      selection.left * size.width,
      selection.top * size.height,
      selection.width * size.width,
      selection.height * size.height,
    );

    final Path mask = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(rect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.35));

    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppColors.primary,
    );

    final Paint handle = Paint()..color = AppColors.primary;
    for (final Offset p in <Offset>[
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(p, dragging ? 4 : 6, handle);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.selection != selection || old.dragging != dragging;
}
