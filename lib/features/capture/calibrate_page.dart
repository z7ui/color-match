import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../core/app_theme.dart';
import '../../core/calibration.dart';

/// 标定页：在照片上框选一块「应该是白色」的区域（白纸 / 灰卡）。
///
/// 交互：拖动移动选框，双指缩放调整大小；底部实时显示平均 RGB。
class CalibratePage extends StatefulWidget {
  const CalibratePage({super.key, required this.imagePath});

  final String imagePath;

  @override
  State<CalibratePage> createState() => _CalibratePageState();
}

class _CalibratePageState extends State<CalibratePage> {
  img.Image? _image;
  Rect _selection = const Rect.fromLTWH(0.35, 0.35, 0.3, 0.3);
  WhitePoint? _white;
  double? _spread;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final img.Image? decoded =
          img.decodeImage(await File(widget.imagePath).readAsBytes());
      if (decoded == null) {
        setState(() => _error = '图片解析失败');
        return;
      }
      setState(() => _image = decoded);
      _sampleSelection();
    } catch (error) {
      setState(() => _error = '读取失败：$error');
    }
  }

  void _sampleSelection() {
    final img.Image? image = _image;
    if (image == null) return;
    final int x = (_selection.left * image.width).round();
    final int y = (_selection.top * image.height).round();
    final int w = (_selection.width * image.width).round();
    final int h = (_selection.height * image.height).round();
    final WhitePoint white = sampleAverage(image, x, y, w, h);

    // 均匀度：框内亮度的 P5-P95 跨度，复用灰阶靶的判定（<=15 才算能用来标定）
    final List<int> lum = <int>[];
    final int x1 = x.clamp(0, image.width - 1);
    final int y1 = y.clamp(0, image.height - 1);
    final int x2 = (x + w).clamp(x1 + 1, image.width);
    final int y2 = (y + h).clamp(y1 + 1, image.height);
    for (int py = y1; py < y2; py += 2) {
      for (int px = x1; px < x2; px += 2) {
        final img.Pixel pixel = image.getPixel(px, py);
        lum.add((0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b).round());
      }
    }
    double spread = 0;
    if (lum.length > 4) {
      lum.sort();
      final int lo = lum[(lum.length * 0.05).floor()];
      final int hi = lum[(lum.length * 0.95).floor().clamp(0, lum.length - 1)];
      spread = (hi - lo).toDouble();
    }

    setState(() {
      _white = white;
      _spread = spread;
    });
  }

  @override
  Widget build(BuildContext context) {
    final img.Image? image = _image;
    return Scaffold(
      appBar: buildAppBar(context, '框选白纸'),
      body: image == null
          ? Center(
              child: _error != null
                  ? Text(_error!, style: const TextStyle(color: AppColors.danger))
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
                      return Center(
                        child: GestureDetector(
                          onPanUpdate: (DragUpdateDetails details) {
                            final double dx = details.delta.dx / box.width;
                            final double dy = details.delta.dy / box.height;
                            setState(() {
                              _selection = _selection.shift(Offset(dx, dy));
                              _clamp();
                            });
                            _sampleSelection();
                          },
                          onScaleUpdate: (ScaleUpdateDetails details) {
                            if (details.scale == 1.0) return;
                            final double next = (_selection.width * details.scale)
                                .clamp(0.05, 0.95);
                            setState(() {
                              _selection = Rect.fromCenter(
                                center: _selection.center,
                                width: next,
                                height: next,
                              );
                              _clamp();
                            });
                            _sampleSelection();
                          },
                          child: SizedBox(
                            width: box.width,
                            height: box.height,
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                Image.file(File(widget.imagePath),
                                    fit: BoxFit.fill),
                                CustomPaint(
                                  painter: _SelectionPainter(_selection),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  color: AppColors.page(context),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _white == null
                            ? '正在采样…'
                            : '平均色 ${_white!}　·　块内跨度 ${_spread?.toStringAsFixed(0) ?? '-'}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      if (_white != null) ...<Widget>[
                        const SizedBox(height: 6),
                        _qualityHint(),
                      ],
                      const SizedBox(height: 4),
                      const Text(
                        '框里只能有白纸/灰卡，别框到瓷砖或阴影。',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton(
                        onPressed: _white == null
                            ? null
                            : () => Navigator.of(context).pop(_white),
                        child: const Text('用这个白点'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// 白纸质量自检：沿用 A4 灰阶靶的三条硬指标里能在这里判断的两条。
  Widget _qualityHint() {
    final WhitePoint white = _white!;
    final double luminance =
        0.2126 * white.r + 0.7152 * white.g + 0.0722 * white.b;
    final List<String> issues = <String>[];
    if (luminance < 235) {
      issues.add('白参考偏低（${luminance.toStringAsFixed(0)}，应 ≥235）：光不够或相机欠曝');
    }
    if ((_spread ?? 0) > 15) {
      issues.add('块内不匀（跨度 ${_spread!.toStringAsFixed(0)}，应 ≤15）：框里有反光或阴影');
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

  void _clamp() {
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
  _SelectionPainter(this.selection);

  final Rect selection;

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
      canvas.drawCircle(p, 6, handle);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.selection != selection;
}
