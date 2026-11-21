import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'calibration.dart';

/// 一次对比的结果。
///
/// 分工是固定的：**参照（家里）是基准，永远不动**；只把目标（工地）拉到参照的光线下。
/// 早先把参照也标定到 255，等于把「你要对比的那张照片」改了颜色，
/// 用户看到的颜色和现场就不是一回事了 —— 那是错的。
class CompareResult {
  const CompareResult({
    required this.processed,
    required this.deltaEBefore,
    required this.deltaEAfter,
    required this.referenceColor,
    required this.targetColorBefore,
    required this.targetColorAfter,
    this.errorFloor,
  });

  /// 目标图拉到参照白点后的成品（「这块砖搬到我家灯下大概这样」）。
  final img.Image processed;

  /// 校正前：工地原图 vs 家里原图（你在两个现场各自看到的差异）。
  final double deltaEBefore;

  /// 校正后：工地「拉到家里光线」后 vs 家里原图（排除光源差异后的真实色差）。
  final double deltaEAfter;

  final WhitePoint referenceColor;
  final WhitePoint targetColorBefore;
  final WhitePoint targetColorAfter;

  /// 误差下限：两张图里「同一块已知物」迁移后仍然差多少。
  ///
  /// 这是白纸（已强制对齐）给不了的信息——白点必然对齐，但相机非线性、截断、
  /// 光源光谱差异会留下残差。null 表示这一组没有标已知物，量不出来。
  final double? errorFloor;

  /// 扣掉误差下限之后的可信差异：sqrt(max(0, ΔE² - floor²))。
  ///
  /// ΔE 小于误差下限时返回 0 —— 说明「这次对比分辨不出来」，不是「完全一样」。
  double get trustworthy {
    final double? floor = errorFloor;
    if (floor == null) return deltaEAfter;
    final double sq = deltaEAfter * deltaEAfter - floor * floor;
    return sq <= 0 ? 0 : math.sqrt(sq);
  }

  /// 改善比例，夹在 0..1。校正后反而更差时给 0，而不是负数。
  double get improvement {
    if (deltaEBefore <= 0.01) return 0;
    return ((deltaEBefore - deltaEAfter) / deltaEBefore).clamp(0.0, 1.0);
  }

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

/// 把目标图从它在工地的白点，迁到参照（家里）的白点，并算校正前后的色差。
///
/// [reference] 是**家里原图**，只读不写；[targetRaw] 是工地原图。
/// 两边白点都只是「测出来的数值」，不改任何一张照片。
CompareResult compareToReference({
  required img.Image reference,
  required img.Image targetRaw,
  required WhitePoint referenceWhite,
  required WhitePoint targetWhite,
  WhitePoint? referenceChecker,
  WhitePoint? targetChecker,
}) {
  // 只动目标：把工地的白点搬到家里的白点上，主人的房子保持原样
  final img.Image processed = transferWhite(
    targetRaw,
    from: targetWhite,
    to: referenceWhite,
  );

  final WhitePoint refColor = centerColor(reference);
  final WhitePoint before = centerColor(targetRaw);
  final WhitePoint after = centerColor(processed);

  return CompareResult(
    processed: processed,
    deltaEBefore: _deltaE(refColor, before),
    deltaEAfter: _deltaE(refColor, after),
    referenceColor: refColor,
    targetColorBefore: before,
    targetColorAfter: after,
    errorFloor: errorFloor(
      referenceChecker: referenceChecker,
      targetChecker: targetChecker,
      referenceWhite: referenceWhite,
      targetWhite: targetWhite,
    ),
  );
}

/// 误差下限：把目标侧的已知物按同一套增益搬过来，再和参照侧的已知物比。
///
/// 同一样东西、同样光线下应该几乎一样；差多少，就是这套流程的分辨力下限。
/// 任一侧没标已知物 → null。
double? errorFloor({
  required WhitePoint? referenceChecker,
  required WhitePoint? targetChecker,
  required WhitePoint referenceWhite,
  required WhitePoint targetWhite,
}) {
  if (referenceChecker == null || targetChecker == null) return null;
  final WhitePoint migrated = migrateColor(
    targetChecker,
    from: targetWhite,
    to: referenceWhite,
  );
  return _deltaE(referenceChecker, migrated);
}

double _deltaE(WhitePoint a, WhitePoint b) => deltaE00(
      rgbToLab(a.r.round(), a.g.round(), a.b.round()),
      rgbToLab(b.r.round(), b.g.round(), b.b.round()),
    );

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
