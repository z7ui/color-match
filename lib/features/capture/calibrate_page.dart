import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../core/app_theme.dart';
import '../../core/calibration.dart';
import '../../core/image_pipeline.dart';

/// 标定结果：用于对齐的白点，和（可选的）另一块已知物。
///
/// 已知物的用途是「自检」：它和白点不同，不会被强制对齐，
/// 所以两张图各读一次、迁移后再比，差值就是这套流程的误差下限。
class Calibration {
  const Calibration({required this.white, this.checker});

  final WhitePoint white;
  final WhitePoint? checker;
}

/// 标定页：在一张照片上框两块区域。
///
/// * **白点**（必填）：白纸 / 灰卡，告诉软件「这里的光偏什么色」；
/// * **已知物**（可选）：同一次拍摄里的另一件已知颜色（灰卡中灰、样板、名片），
///   用来自检这套流程准到几分。
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
  WhitePoint? _checker;
  double? _spread;
  double? _checkSpread;
  String? _error;

  Rect _whiteSel = const Rect.fromLTWH(0.35, 0.35, 0.30, 0.30);
  Rect _checkSel = const Rect.fromLTWH(0.06, 0.66, 0.20, 0.20);
  bool _useChecker = false;
  bool _editingChecker = false;
  bool _dragging = false;
  double _startWidth = 0.30;
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

  Rect get _activeSel => _editingChecker && _useChecker ? _checkSel : _whiteSel;

  void _sample({int stride = 1}) {
    final img.Image? image = _preview;
    if (image == null) return;
    setState(() {
      _white = _sampleRect(image, _whiteSel, stride);
      _spread = _spreadRect(image, _whiteSel, stride);
      if (_useChecker) {
        _checker = _sampleRect(image, _checkSel, stride);
        _checkSpread = _spreadRect(image, _checkSel, stride);
      } else {
        _checker = null;
        _checkSpread = null;
      }
    });
  }

  WhitePoint _sampleRect(img.Image image, Rect sel, int stride) {
    return sampleAverage(
      image,
      (sel.left * image.width).round(),
      (sel.top * image.height).round(),
      (sel.width * image.width).round(),
      (sel.height * image.height).round(),
      stride: stride,
    );
  }

  double _spreadRect(img.Image image, Rect sel, int stride) {
    return luminanceSpread(
      image,
      (sel.left * image.width).round(),
      (sel.top * image.height).round(),
      (sel.width * image.width).round(),
      (sel.height * image.height).round(),
      stride: stride < 2 ? 2 : stride,
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startWidth = _activeSel.width;
    _dragging = true;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      Rect next = _activeSel;
      if (details.pointerCount == 1) {
        final Size view = _viewSize;
        if (view.width > 0 && view.height > 0) {
          next = next.translate(
            details.focalPointDelta.dx / view.width,
            details.focalPointDelta.dy / view.height,
          );
        }
      } else {
        // 双指缩放：以起始宽度乘以手势比例（别用上一帧的值，会指数放大）
        final double w = (_startWidth * details.scale).clamp(0.05, 0.95);
        next = Rect.fromCenter(center: next.center, width: w, height: w);
      }
      next = _clamp(next);
      if (_editingChecker && _useChecker) {
        _checkSel = next;
      } else {
        _whiteSel = next;
      }
    });
    _sample(stride: 4);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _dragging = false;
    _sample();
  }

  Rect _clamp(Rect r) {
    final double w = r.width.clamp(0.05, 0.95);
    final double h = r.height.clamp(0.05, 0.95);
    final double left = r.left.clamp(0.0, 1 - w);
    final double top = r.top.clamp(0.0, 1 - h);
    return Rect.fromLTWH(left, top, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final img.Image? image = _preview;
    return Scaffold(
      appBar: buildAppBar('框选白点'),
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
                                    whiteSel: _whiteSel,
                                    checkSel: _useChecker ? _checkSel : null,
                                    activeIsChecker: _editingChecker,
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
    final WhitePoint? checker = _checker;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      color: AppColors.page(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _useChecker,
            onChanged: (bool v) {
              setState(() {
                _useChecker = v;
                if (!v) _editingChecker = false;
              });
              _sample();
            },
            title: const Text('同时记录一块已知物（可选，用于自检）',
                style: TextStyle(fontSize: 13)),
            subtitle: const Text('灰卡 / 同一块样板 / 名片都行，两张照片里放同一件',
                style: TextStyle(fontSize: 11)),
          ),
          if (_useChecker)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SegmentedButton<bool>(
                segments: const <ButtonSegment<bool>>[
                  ButtonSegment<bool>(value: false, label: Text('编辑：白点')),
                  ButtonSegment<bool>(value: true, label: Text('编辑：已知物')),
                ],
                selected: <bool>{_editingChecker},
                onSelectionChanged: (Set<bool> v) =>
                    setState(() => _editingChecker = v.first),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          Row(
            children: <Widget>[
              _swatch(white),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  white == null
                      ? '正在采样…'
                      : '白点 $white　·　跨度 ${_spread?.toStringAsFixed(0) ?? '-'}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          if (_useChecker) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                _swatch(checker),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    checker == null
                        ? '正在采样…'
                        : '已知物 $checker　·　跨度 ${_checkSpread?.toStringAsFixed(0) ?? '-'}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
          if (white != null) ...<Widget>[
            const SizedBox(height: 6),
            _qualityHint(white),
          ],
          const SizedBox(height: 4),
          Text(
            _useChecker
                ? '白点用来对齐光线；已知物用来自检——两边的已知物迁移后应该几乎一样，差多少就是这套流程的误差下限。'
                : '框住画面里那块白（纸的一角就够），别框到瓷砖或阴影。单指拖动，双指缩放。白点只用来对齐光线，这张照片本身不会被改。',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: white == null
                  ? null
                  : () => Navigator.of(context).pop(Calibration(
                        white: white,
                        checker: _useChecker ? checker : null,
                      )),
              child: const Text('确认'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _swatch(WhitePoint? point) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: point == null
            ? AppColors.line(context)
            : Color.fromARGB(
                255,
                point.r.round().clamp(0, 255),
                point.g.round().clamp(0, 255),
                point.b.round().clamp(0, 255),
              ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.line(context)),
      ),
    );
  }

  /// 白纸质量自检：能不能用来定白点。
  Widget _qualityHint(WhitePoint white) {
    final List<String> issues = <String>[];
    final double spread = _spread ?? 0;
    final double maxCh = <double>[white.r, white.g, white.b].reduce(mathMax);
    if (white.luminance < 120) {
      issues.add('这块白偏暗（${white.luminance.toStringAsFixed(0)}）：拉平别的照片时容易把高光拉爆，建议补光或换块白纸');
    }
    if (white.luminance > 246 || maxCh >= 254) {
      issues.add('疑似过曝（最亮通道 ${maxCh.toStringAsFixed(0)}）：压到 255 就测不准了，往下压一点曝光再拍');
    }
    if (spread > 10) {
      issues.add('块内不匀（跨度 ${spread.toStringAsFixed(0)}，应 ≤10）：框里有反光或阴影');
    }
    if (white.chromaSpread > 12) {
      issues.add('这块白偏色（通道差 ${white.chromaSpread.toStringAsFixed(0)}，应 ≤12）：可能框到了带颜色的纸，或者这块白不中性');
    }
    if (issues.isEmpty) {
      return const Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline, size: 16, color: AppColors.success),
          SizedBox(width: 4),
          Expanded(
            child: Text('这块白可以用了（灰卡 / 白卡比打印纸更准，打印纸含荧光增白剂）',
                style: TextStyle(fontSize: 12, color: AppColors.success)),
          ),
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

double mathMax(double a, double b) => a > b ? a : b;

class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required this.whiteSel,
    required this.checkSel,
    required this.activeIsChecker,
    required this.dragging,
  });

  final Rect whiteSel;
  final Rect? checkSel;
  final bool activeIsChecker;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect whiteRect = _toPixels(whiteSel, size);
    final Rect? checkRect =
        checkSel == null ? null : _toPixels(checkSel!, size);

    final Path mask = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    mask.addRect(whiteRect);
    if (checkRect != null) mask.addRect(checkRect);
    mask.fillType = PathFillType.evenOdd;
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.38));

    _stroke(canvas, whiteRect, AppColors.primary,
        active: !activeIsChecker, dragging: dragging);
    if (checkRect != null) {
      _stroke(canvas, checkRect, AppColors.warning,
          active: activeIsChecker, dragging: dragging);
    }
  }

  Rect _toPixels(Rect r, Size size) => Rect.fromLTWH(
        r.left * size.width,
        r.top * size.height,
        r.width * size.width,
        r.height * size.height,
      );

  void _stroke(Canvas canvas, Rect rect, Color color,
      {required bool active, required bool dragging}) {
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2.5 : 1.5
        ..color = color.withValues(alpha: active ? 1 : 0.55),
    );
    final Paint handle = Paint()..color = color;
    for (final Offset p in <Offset>[
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(p, active && dragging ? 4 : 6, handle);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.whiteSel != whiteSel ||
      old.checkSel != checkSel ||
      old.activeIsChecker != activeIsChecker ||
      old.dragging != dragging;
}
