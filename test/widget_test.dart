import 'package:flutter_test/flutter_test.dart';

import 'package:color_match/core/calibration.dart';

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
}
