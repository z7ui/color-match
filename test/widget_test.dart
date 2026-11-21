import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:color_match/core/calibration.dart';
import 'package:color_match/core/compare.dart';

void main() {
  test('ΔE00 of identical colors is zero', () {
    final List<double> lab = rgbToLab(128, 128, 128);
    expect(deltaE00(lab, lab), 0);
  });

  test('ΔE00 grows with lightness difference', () {
    final List<double> light = rgbToLab(200, 200, 200);
    final List<double> dark = rgbToLab(100, 100, 100);
    expect(deltaE00(light, dark), greaterThan(10));
  });

  test('white point validity rejects near-black', () {
    expect(const WhitePoint(0, 0, 0).isValid, isFalse);
    expect(const WhitePoint(240, 240, 240).isValid, isTrue);
  });

  test('compare uses same 255 basis for reference and corrected target', () {
    // 参照：白点 240 的灰图，标定到 255 后中心值约 255*? ——用纯色构造更直接。
    // 参照原图中心 240，标定后 255；目标原图中心 240、白点也是 240，标定后同样 255。
    // 两边标定后应完全一致，ΔEafter ≈ 0。
    final img.Image ref = img.Image(width: 100, height: 100);
    final img.Image target = img.Image(width: 100, height: 100);
    for (final img.Pixel p in ref) {
      p.r = 240; p.g = 240; p.b = 240;
    }
    for (final img.Pixel p in target) {
      p.r = 240; p.g = 240; p.b = 240;
    }

    final CompareResult result = compareToReference(
      reference: applyWhiteBalance(ref, white: const WhitePoint(240, 240, 240)),
      target: target,
      referenceWhite: const WhitePoint(240, 240, 240),
      targetWhite: const WhitePoint(240, 240, 240),
    );
    expect(result.deltaEAfter, lessThan(1));
  });
}
