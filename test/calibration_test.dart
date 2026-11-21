import 'package:color_match/core/calibration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  group('CIEDE2000（对照 Sharma 数据集）', () {
    test('标准样本 1：期望 2.0425', () {
      // Sharma et al. 2005 的参考数据，用来确认公式实现没走样
      final double d = deltaE00(
        <double>[50, 2.6772, -79.7751],
        <double>[50, 0, -82.7485],
      );
      expect(d, closeTo(2.0425, 0.0001));
    });

    test('标准样本 2：期望 2.8615', () {
      final double d = deltaE00(
        <double>[50, 3.1571, -77.2803],
        <double>[50, 0, -82.7485],
      );
      expect(d, closeTo(2.8615, 0.0001));
    });

    test('对称', () {
      final List<double> a = rgbToLab(120, 90, 60);
      final List<double> b = rgbToLab(30, 40, 200);
      expect(deltaE00(a, b), closeTo(deltaE00(b, a), 1e-9));
    });

    test('同色为 0，黑白约 100', () {
      expect(deltaE00Rgb(128, 128, 128, 128, 128, 128), closeTo(0, 1e-9));
      expect(deltaE00Rgb(255, 255, 255, 0, 0, 0), greaterThan(95));
    });
  });

  group('白点有效性', () {
    test('接近全黑的区域不可用', () {
      expect(const WhitePoint(0, 0, 0).isValid, isFalse);
      expect(const WhitePoint(5, 5, 5).isValid, isFalse);
      expect(const WhitePoint(240, 240, 240).isValid, isTrue);
    });

    test('偏色检测', () {
      expect(const WhitePoint(240, 240, 240).chromaSpread, 0);
      expect(const WhitePoint(240, 200, 180).chromaSpread, 60);
    });
  });

  group('白平衡', () {
    test('增益被夹住：白点很暗也不会把图拉爆', () {
      final img.Image dark = img.Image(width: 8, height: 8);
      for (final img.Pixel p in dark) {
        p.r = 8;
        p.g = 8;
        p.b = 8;
      }
      final img.Image out =
          applyWhiteBalance(dark, white: const WhitePoint(8, 8, 8));
      // 未夹住时 255/8 ≈ 32 倍，会直接 255；夹到 4 倍后应该还是个暗灰
      expect(out.getPixel(4, 4).r, lessThan(60));
    });

    test('正常白点会被拉到接近 255', () {
      final img.Image gray = img.Image(width: 8, height: 8);
      for (final img.Pixel p in gray) {
        p.r = 200;
        p.g = 200;
        p.b = 200;
      }
      final img.Image out =
          applyWhiteBalance(gray, white: const WhitePoint(200, 200, 200));
      expect(out.getPixel(4, 4).r, greaterThan(240));
    });

    test('白点无效时原样返回', () {
      final img.Image gray = img.Image(width: 4, height: 4);
      for (final img.Pixel p in gray) {
        p.r = 10;
        p.g = 20;
        p.b = 30;
      }
      final img.Image out =
          applyWhiteBalance(gray, white: const WhitePoint(0, 0, 0));
      expect(out.getPixel(1, 1).r, 10);
      expect(out.getPixel(1, 1).b, 30);
    });

    test('transferWhite 把目标拉向参照白点', () {
      final img.Image gray = img.Image(width: 4, height: 4);
      for (final img.Pixel p in gray) {
        p.r = 150;
        p.g = 150;
        p.b = 150;
      }
      final img.Image out = transferWhite(
        gray,
        from: const WhitePoint(150, 150, 150),
        to: const WhitePoint(230, 230, 230),
      );
      // 1.53 倍增益，150 -> 约 205（线性光换算后）
      expect(out.getPixel(1, 1).r, greaterThan(190));
    });
  });

  group('采样', () {
    test('stride 不影响平均色太多', () {
      final img.Image image = img.Image(width: 40, height: 40);
      for (final img.Pixel p in image) {
        p.r = 100;
        p.g = 110;
        p.b = 120;
      }
      final WhitePoint s1 = sampleAverage(image, 0, 0, 40, 40);
      final WhitePoint s4 = sampleAverage(image, 0, 0, 40, 40, stride: 4);
      expect(s1.r, closeTo(s4.r, 0.5));
      expect(s1.b, closeTo(s4.b, 0.5));
    });

    test('均匀区域跨度为 0', () {
      final img.Image image = img.Image(width: 20, height: 20);
      for (final img.Pixel p in image) {
        p.r = 200;
        p.g = 200;
        p.b = 200;
      }
      expect(luminanceSpread(image, 0, 0, 20, 20), 0);
    });
  });
}
