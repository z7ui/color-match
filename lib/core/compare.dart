import 'package:image/image.dart' as img;

import 'calibration.dart';

/// 一次对比的结果。
class CompareResult {
  const CompareResult({
    required this.processed,
    required this.deltaEBefore,
    required this.deltaEAfter,
    required this.referenceColor,
    required this.targetColorBefore,
    required this.targetColorAfter,
  });

  /// 目标图拉到参照白点后的成品。
  final img.Image processed;

  /// 校正前：两张**原始照片**直接比（用户肉眼看到的差异）。
  final double deltaEBefore;

  /// 校正后：两张都标定到 255 基准后比（同一基准）。
  final double deltaEAfter;

  final WhitePoint referenceColor;
  final WhitePoint targetColorBefore;
  final WhitePoint targetColorAfter;

  /// 改善比例，夹在 0..1。校正后反而更差时给 0，而不是负数。
  double get improvement {
    if (deltaEBefore <= 0.01) return 0;
    return ((deltaEBefore - deltaEAfter) / deltaEBefore).clamp(0.0, 1.0);
  }

  /// 是否显著改善（ΔE 降了 0.5 以上）。
  bool get improved => deltaEAfter < deltaEBefore - 0.5;
}

/// 在图的中心取一块（默认 40%）算平均色，代表「主色」。
WhitePoint centerColor(img.Image image, {double ratio = 0.4, int stride = 1}) {
  final int w = (image.width * ratio).round();
  final int h = (image.height * ratio).round();
  final int x = (image.width - w) ~/ 2;
  final int y = (image.height - h) ~/ 2;
  return sampleAverage(image, x, y, w, h, stride: stride);
}

/// 把目标图从自己的白点拉到参照白点，并算校正前后的色差。
///
/// 基准说明（之前这里是不一致的，会说白话把人骗了）：
/// * [deltaEBefore] 用**两张原始图**比 —— 那是用户站在现场看到的差异；
/// * [deltaEAfter] 用**两张都标定到 255** 的图比 —— 排除光源后的真实色差。
/// 两者都自洽，不能再出现「一个已标定、一个没标定」的混合基准。
CompareResult compareToReference({
  required img.Image referenceRaw,
  required img.Image referenceCalibrated,
  required img.Image targetRaw,
  required WhitePoint referenceWhite,
  required WhitePoint targetWhite,
}) {
  // 目标先用自己的白点标定到 255，和参照标定图同一基准
  final img.Image targetNormalized =
      applyWhiteBalance(targetRaw, white: targetWhite);

  // 展示给用户的「拉平后」图：目标原始白点 -> 参照白点（保留参照环境的光）
  final img.Image processed = transferWhite(
    targetRaw,
    from: targetWhite,
    to: referenceWhite,
  );

  final WhitePoint refRawColor = centerColor(referenceRaw);
  final WhitePoint refColor = centerColor(referenceCalibrated);
  final WhitePoint before = centerColor(targetRaw);
  final WhitePoint after = centerColor(targetNormalized);

  final double eBefore = _deltaE(refRawColor, before);
  final double eAfter = _deltaE(refColor, after);

  return CompareResult(
    processed: processed,
    deltaEBefore: eBefore,
    deltaEAfter: eAfter,
    referenceColor: refColor,
    targetColorBefore: before,
    targetColorAfter: after,
  );
}

double _deltaE(WhitePoint a, WhitePoint b) => deltaE00(
      rgbToLab(a.r.round(), a.g.round(), a.b.round()),
      rgbToLab(b.r.round(), b.g.round(), b.b.round()),
    );

/// 把两张图拼成一张对比图：左参考、中目标（校正前）、右目标（校正后）。
img.Image buildSideBySide({
  required img.Image reference,
  required img.Image targetBefore,
  required img.Image targetAfter,
  int gap = 24,
}) {
  final int w = reference.width + targetBefore.width + targetAfter.width + gap * 4;
  final int h = <int>[
        reference.height,
        targetBefore.height,
        targetAfter.height,
      ].reduce((int a, int b) => a > b ? a : b) +
      gap * 2;

  final img.Image canvas = img.Image(width: w, height: h);
  img.fill(canvas, color: img.ColorRgb8(245, 246, 248));

  int x = gap;
  img.compositeImage(canvas, reference, dstX: x, dstY: gap);
  x += reference.width + gap;
  img.compositeImage(canvas, targetBefore, dstX: x, dstY: gap);
  x += targetBefore.width + gap;
  img.compositeImage(canvas, targetAfter, dstX: x, dstY: gap);

  return canvas;
}

/// 一行对比：参照 | 目标（校正前） | 目标（校正后）。
img.Image buildRow({
  required img.Image reference,
  required img.Image before,
  required img.Image after,
  required String label,
  int gap = 16,
}) {
  const int labelHeight = 34;
  final int contentHeight = <int>[
    reference.height,
    before.height,
    after.height,
  ].reduce((int a, int b) => a > b ? a : b);
  final int h = contentHeight + labelHeight + gap * 2;
  final int w = reference.width + before.width + after.width + gap * 4;

  final img.Image canvas = img.Image(width: w, height: h);
  img.fill(canvas, color: img.ColorRgb8(245, 246, 248));

  int x = gap;
  img.compositeImage(canvas, reference, dstX: x, dstY: gap);
  x += reference.width + gap;
  img.compositeImage(canvas, before, dstX: x, dstY: gap);
  x += before.width + gap;
  img.compositeImage(canvas, after, dstX: x, dstY: gap);

  // 标签用内置 ASCII 字体（中文会变方块），只放简短标识
  img.drawString(
    canvas,
    label,
    font: img.arial24,
    x: gap,
    y: gap + contentHeight + 4,
    color: img.ColorRgb8(70, 76, 84),
  );
  return canvas;
}

/// 多行纵向拼接（每行之间留 24px）。
img.Image buildVerticalReport(List<img.Image> rows, {int gap = 24}) {
  if (rows.isEmpty) return img.Image(width: 10, height: 10);
  final int w = rows
      .map((img.Image r) => r.width)
      .reduce((int a, int b) => a > b ? a : b);
  final int h =
      rows.map((img.Image r) => r.height).reduce((int a, int b) => a + b) +
          gap * (rows.length + 1);

  final img.Image canvas = img.Image(width: w, height: h);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));

  int y = gap;
  for (final img.Image row in rows) {
    img.compositeImage(canvas, row, dstX: (w - row.width) ~/ 2, dstY: y);
    y += row.height + gap;
  }
  return canvas;
}
