import 'package:color_match/core/calibration.dart';
import 'package:color_match/core/compare.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image solid(int v, {int w = 64, int h = 64}) {
  final img.Image image = img.Image(width: w, height: h);
  for (final img.Pixel p in image) {
    p.r = v;
    p.g = v;
    p.b = v;
  }
  return image;
}

void main() {
  group('参照（家里）必须保持原样', () {
    test('对比不会修改参照图的任何像素', () {
      final img.Image reference = solid(97);
      final img.Image target = solid(180);

      compareToReference(
        reference: reference,
        targetRaw: target,
        referenceWhite: const WhitePoint(97, 97, 97),
        targetWhite: const WhitePoint(180, 180, 180),
      );

      // 整张参照图一个像素都不能变：它就是「你要对比的那张照片」
      for (final img.Pixel p in reference) {
        expect(p.r, 97);
        expect(p.g, 97);
        expect(p.b, 97);
      }
    });

    test('对比不会修改目标原图', () {
      final img.Image reference = solid(120);
      final img.Image target = solid(200);
      compareToReference(
        reference: reference,
        targetRaw: target,
        referenceWhite: const WhitePoint(120, 120, 120),
        targetWhite: const WhitePoint(200, 200, 200),
      );
      for (final img.Pixel p in target) {
        expect(p.r, 200);
      }
    });
  });

  group('把工地拉到家里的光线', () {
    test('同一张灰卡：校正前差异大，校正后几乎为 0', () {
      final img.Image reference = solid(100);
      final img.Image target = solid(200);

      final CompareResult result = compareToReference(
        reference: reference,
        targetRaw: target,
        referenceWhite: const WhitePoint(100, 100, 100),
        targetWhite: const WhitePoint(200, 200, 200),
      );

      expect(result.deltaEBefore, greaterThan(20));
      expect(result.deltaEAfter, lessThan(1.5));
      expect(result.improvement, greaterThan(0.9));
    });

    test('彩色目标：拉过来后白点一致，色相不变', () {
      final img.Image reference = solid(150);
      final img.Image target = img.Image(width: 64, height: 64);
      for (final img.Pixel p in target) {
        // 一块偏蓝白的瓷砖（工地冷光下拍的）
        p.r = 150;
        p.g = 165;
        p.b = 190;
      }

      final CompareResult result = compareToReference(
        reference: reference,
        targetRaw: target,
        referenceWhite: const WhitePoint(150, 150, 150),
        targetWhite: const WhitePoint(150, 165, 190),
      );

      // 目标的白点被搬到参照的白点附近
      expect(result.targetColorAfter.r, closeTo(150, 12));
      expect(result.targetColorAfter.g, closeTo(150, 12));
      expect(result.targetColorAfter.b, closeTo(150, 12));
      // 原始白点还在（只是不再用于判定）
      expect(result.targetColorBefore.b, greaterThan(180));
    });

    test('改善比例夹在 0..1', () {
      final img.Image reference = solid(128);
      final img.Image target = img.Image(width: 64, height: 64);
      for (final img.Pixel p in target) {
        p.r = 120;
        p.g = 128;
        p.b = 220;
      }
      final CompareResult result = compareToReference(
        reference: reference,
        targetRaw: target,
        referenceWhite: const WhitePoint(128, 128, 128),
        targetWhite: const WhitePoint(128, 128, 128),
      );
      expect(result.improvement, inInclusiveRange(0.0, 1.0));
    });
  });

  group('中心取色', () {
    test('用 40% 区域，不受边缘影响', () {
      final img.Image image = img.Image(width: 100, height: 100);
      for (final img.Pixel p in image) {
        p.r = 0;
        p.g = 0;
        p.b = 0;
      }
      for (int y = 30; y < 70; y++) {
        for (int x = 30; x < 70; x++) {
          final img.Pixel p = image.getPixel(x, y);
          p.r = 200;
          p.g = 200;
          p.b = 200;
        }
      }
      expect(centerColor(image).r, closeTo(200, 1));
    });
  });
}
