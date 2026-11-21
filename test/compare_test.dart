import 'package:color_match/core/calibration.dart';
import 'package:color_match/core/compare.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image solid(int v) {
  final img.Image image = img.Image(width: 64, height: 64);
  for (final img.Pixel p in image) {
    p.r = v;
    p.g = v;
    p.b = v;
  }
  return image;
}

void main() {
  group('对比基准一致性', () {
    test('同一张灰卡：校正前有差异，校正后几乎为 0', () {
      // 参照 100 灰（自家灯光偏暗），目标 200 灰（厂里灯亮）：都是中性灰
      final img.Image refRaw = solid(100);
      final img.Image refCal = applyWhiteBalance(refRaw,
          white: const WhitePoint(100, 100, 100));
      final img.Image targetRaw = solid(200);

      final CompareResult result = compareToReference(
        referenceRaw: refRaw,
        referenceCalibrated: refCal,
        targetRaw: targetRaw,
        referenceWhite: const WhitePoint(100, 100, 100),
        targetWhite: const WhitePoint(200, 200, 200),
      );

      // 校正前：两张原始照片亮度差一大截
      expect(result.deltaEBefore, greaterThan(20));
      // 校正后：都拉到 255 基准，同一中性灰应该几乎一样
      expect(result.deltaEAfter, lessThan(1.5));
      expect(result.improvement, greaterThan(0.8));
    });

    test('改善比例夹在 0..1，不会出现负数', () {
      final img.Image refRaw = solid(128);
      final img.Image refCal = applyWhiteBalance(refRaw,
          white: const WhitePoint(128, 128, 128));
      // 目标偏蓝：校正后反而更不像
      final img.Image target = img.Image(width: 64, height: 64);
      for (final img.Pixel p in target) {
        p.r = 120;
        p.g = 128;
        p.b = 220;
      }
      final CompareResult result = compareToReference(
        referenceRaw: refRaw,
        referenceCalibrated: refCal,
        targetRaw: target,
        referenceWhite: const WhitePoint(128, 128, 128),
        targetWhite: const WhitePoint(128, 128, 128),
      );
      expect(result.improvement, inInclusiveRange(0.0, 1.0));
    });

    test('中心取色用 40% 区域，不受边缘影响', () {
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
      final WhitePoint center = centerColor(image);
      expect(center.r, closeTo(200, 1));
    });
  });
}
