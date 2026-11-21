import 'package:color_match/core/ccm.dart';
import 'package:color_match/core/calibration.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<double>> referenceLinear() => <List<double>>[
      for (final List<int> rgb in ColorChecker.srgb)
        <double>[srgbToLinear(rgb[0]), srgbToLinear(rgb[1]), srgbToLinear(rgb[2])],
    ];

void main() {
  group('CCM 拟合', () {
    test('实测 = 参考：矩阵≈单位阵、残差≈0', () {
      final List<List<double>> measured = referenceLinear();
      final CameraCcm ccm = fitCcm(measured, measured);
      expect(ccm.matrix[0], closeTo(1, 0.02));
      expect(ccm.matrix[4], closeTo(1, 0.02));
      expect(ccm.matrix[8], closeTo(1, 0.02));
      expect(ccm.matrix[1], closeTo(0, 0.02));
      expect(ccm.matrix[3], closeTo(0, 0.02));
      expect(ccm.offset[0].abs(), lessThan(0.02));
      expect(ccm.meanDelta, lessThan(1));
    });

    test('整体压暗 20%：矩阵≈1.25 对角', () {
      final List<List<double>> reference = referenceLinear();
      final List<List<double>> measured = <List<double>>[
        for (final List<double> rgb in reference)
          <double>[rgb[0] * 0.8, rgb[1] * 0.8, rgb[2] * 0.8],
      ];
      final CameraCcm ccm = fitCcm(measured, reference);
      expect(ccm.matrix[0], closeTo(1.25, 0.05));
      expect(ccm.matrix[4], closeTo(1.25, 0.05));
      expect(ccm.matrix[8], closeTo(1.25, 0.05));
      expect(ccm.meanDelta, lessThan(1.5));
    });

    test('通道串扰能被拟合还原', () {
      final List<List<double>> reference = referenceLinear();
      // 相机把 10% 的红混进了绿
      final List<List<double>> measured = <List<double>>[
        for (final List<double> rgb in reference)
          <double>[rgb[0], rgb[1] + rgb[0] * 0.1, rgb[2]],
      ];
      final CameraCcm ccm = fitCcm(measured, reference);
      final List<double> out = ccm.apply(measured[6]);
      expect(out[1], closeTo(reference[6][1], 0.02));
    });
  });

  group('CameraCcm', () {
    test('输出被夹在 0..1', () {
      const CameraCcm ccm = CameraCcm(
        matrix: <double>[2, 0, 0, 0, 2, 0, 0, 0, 2],
        offset: <double>[0.5, -0.5, 0],
      );
      final List<double> out = ccm.apply(<double>[0.9, 0.2, 0.5]);
      expect(out[0], 1.0);
      expect(out[1], 0.0);
      expect(out[2], closeTo(1.0, 0.001));
    });

    test('JSON 往返', () {
      const CameraCcm ccm = CameraCcm(
        matrix: <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
        offset: <double>[0, 0, 0],
        meanDelta: 1.2,
        maxDelta: 3.4,
      );
      final CameraCcm? back = CameraCcm.fromJson(ccm.toJson());
      expect(back, isNotNull);
      expect(back!.matrix[0], 1);
      expect(back.meanDelta, 1.2);
    });
  });

  group('透视变换', () {
    test('单位四边形是恒等映射', () {
      final Homography h = Homography.fromQuad(const <Offset2>[
        Offset2(0, 0),
        Offset2(1, 0),
        Offset2(1, 1),
        Offset2(0, 1),
      ]);
      final Offset2 mid = h.map(0.5, 0.5);
      expect(mid.x, closeTo(0.5, 0.01));
      expect(mid.y, closeTo(0.5, 0.01));
    });

    test('平移+缩放能还原', () {
      final Homography h = Homography.fromQuad(const <Offset2>[
        Offset2(100, 50),
        Offset2(300, 50),
        Offset2(300, 150),
        Offset2(100, 150),
      ]);
      final Offset2 corner = h.map(1, 1);
      expect(corner.x, closeTo(300, 0.5));
      expect(corner.y, closeTo(150, 0.5));
      final Offset2 center = h.map(0.5, 0.5);
      expect(center.x, closeTo(200, 0.5));
      expect(center.y, closeTo(100, 0.5));
    });
  });
}
