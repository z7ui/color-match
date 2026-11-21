import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'calibration.dart';

/// 24 色卡（ColorChecker Classic）的 sRGB 参考值，行优先 6 列 × 4 行。
///
/// 数值是公开的常见近似值（X-Rite 官方在 D50 下的标称值换算到 sRGB），
/// 用于最小二乘拟合相机 3×3 色彩矩阵。
class ColorChecker {
  ColorChecker._();

  static const List<List<int>> srgb = <List<int>>[
    <int>[115, 82, 68], // 1 深肤色
    <int>[194, 150, 130], // 2 浅肤色
    <int>[98, 122, 157], // 3 蓝天
    <int>[87, 108, 67], // 4 树叶
    <int>[133, 128, 177], // 5 蓝花
    <int>[103, 189, 170], // 6 蓝绿
    <int>[214, 126, 44], // 7 橙
    <int>[80, 91, 166], // 8 紫蓝
    <int>[193, 90, 99], // 9 中红
    <int>[94, 60, 108], // 10 紫
    <int>[157, 188, 64], // 11 黄绿
    <int>[224, 163, 46], // 12 橙黄
    <int>[56, 61, 150], // 13 蓝
    <int>[70, 148, 73], // 14 绿
    <int>[175, 54, 60], // 15 红
    <int>[231, 199, 31], // 16 黄
    <int>[187, 86, 149], // 17 品红
    <int>[8, 133, 161], // 18 青
    <int>[243, 243, 242], // 19 白
    <int>[200, 200, 200], // 20 中性 8
    <int>[160, 160, 160], // 21 中性 6.5
    <int>[122, 122, 121], // 22 中性 5
    <int>[85, 85, 85], // 23 中性 3.5
    <int>[52, 52, 52], // 24 黑
  ];

  static const int columns = 6;
  static const int rows = 4;
}

/// 相机色彩校正矩阵（3×3 + 偏移），作用在**线性光**空间。
class CameraCcm {
  const CameraCcm({required this.matrix, required this.offset, this.meanDelta = 0, this.maxDelta = 0});

  /// 行优先 9 个数。
  final List<double> matrix;
  final List<double> offset;

  /// 拟合时 24 块的平均 / 最大残差（ΔE00），用来判断这块色卡拍得靠不靠谱。
  final double meanDelta;
  final double maxDelta;

  bool get isUsable => meanDelta < 4 && maxDelta < 8;

  /// 应用到一个线性 RGB（0..1），返回校正后的线性 RGB。
  List<double> apply(List<double> rgb) {
    final double r = rgb[0];
    final double g = rgb[1];
    final double b = rgb[2];
    return <double>[
      (matrix[0] * r + matrix[1] * g + matrix[2] * b + offset[0])
          .clamp(0.0, 1.0),
      (matrix[3] * r + matrix[4] * g + matrix[5] * b + offset[1])
          .clamp(0.0, 1.0),
      (matrix[6] * r + matrix[7] * g + matrix[8] * b + offset[2])
          .clamp(0.0, 1.0),
    ];
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'matrix': matrix,
        'offset': offset,
        'mean_delta': meanDelta,
        'max_delta': maxDelta,
        'created_at': DateTime.now().toIso8601String(),
      };

  static CameraCcm? fromJson(Map<String, Object?> json) {
    final Object? matrix = json['matrix'];
    final Object? offset = json['offset'];
    if (matrix is! List || offset is! List) return null;
    if (matrix.length != 9 || offset.length != 3) return null;
    return CameraCcm(
      matrix: matrix.map((Object? v) => (v! as num).toDouble()).toList(),
      offset: offset.map((Object? v) => (v! as num).toDouble()).toList(),
      meanDelta: ((json['mean_delta'] as num?) ?? 0).toDouble(),
      maxDelta: ((json['max_delta'] as num?) ?? 0).toDouble(),
    );
  }
}

/// 透视变换：把单位正方形 (0..1)² 映射到图像里的四边形。
class Homography {
  Homography._(this._m);

  /// 行优先 9 个数，最后一个归一化为 1。
  final List<double> _m;

  /// [quad] 顺序：左上、右上、右下、左下（用户点选顺序）。
  factory Homography.fromQuad(List<Offset2> quad) {
    final List<List<double>> a = <List<double>>[];
    final List<double> b = <double>[];
    const List<List<double>> unit = <List<double>>[
      <double>[0, 0],
      <double>[1, 0],
      <double>[1, 1],
      <double>[0, 1],
    ];
    for (int i = 0; i < 4; i++) {
      final double x = unit[i][0];
      final double y = unit[i][1];
      final double u = quad[i].x;
      final double v = quad[i].y;
      a.add(<double>[x, y, 1, 0, 0, 0, -u * x, -u * y]);
      b.add(u);
      a.add(<double>[0, 0, 0, x, y, 1, -v * x, -v * y]);
      b.add(v);
    }
    final List<double> h = _solve(a, b);
    return Homography._(<double>[
      h[0], h[1], h[2],
      h[3], h[4], h[5],
      h[6], h[7], 1.0,
    ]);
  }

  Offset2 map(double x, double y) {
    final double w = _m[6] * x + _m[7] * y + _m[8];
    final double sx = (_m[0] * x + _m[1] * y + _m[2]) / w;
    final double sy = (_m[3] * x + _m[4] * y + _m[5]) / w;
    return Offset2(sx, sy);
  }

  /// 高斯消元（部分主元）。
  static List<double> _solve(List<List<double>> matrix, List<double> rhs) {
    final int n = rhs.length;
    final List<List<double>> a = <List<double>>[
      for (int i = 0; i < n; i++)
        <double>[...matrix[i], rhs[i]],
    ];
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int r = col + 1; r < n; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      final List<double> tmp = a[col];
      a[col] = a[pivot];
      a[pivot] = tmp;
      final double d = a[col][col];
      if (d.abs() < 1e-12) continue;
      for (int c = col; c <= n; c++) {
        a[col][c] /= d;
      }
      for (int r = 0; r < n; r++) {
        if (r == col) continue;
        final double factor = a[r][col];
        if (factor == 0) continue;
        for (int c = col; c <= n; c++) {
          a[r][c] -= factor * a[col][c];
        }
      }
    }
    return <double>[for (int i = 0; i < n; i++) a[i][n]];
  }
}

class Offset2 {
  const Offset2(this.x, this.y);
  final double x;
  final double y;
  @override
  String toString() => '(' + x.toStringAsFixed(1) + ', ' + y.toStringAsFixed(1) + ')';
}

/// 用 24 色卡的实测值拟合 3×3 矩阵（带一点岭正则，避免病态）。
CameraCcm fitCcm(List<List<double>> measured, List<List<double>> reference) {
  final int n = measured.length;
  const double ridge = 1e-4;
  final List<double> matrix = List<double>.filled(9, 0);
  final List<double> offset = List<double>.filled(3, 0);

  for (int channel = 0; channel < 3; channel++) {
    // 正规方程：A^T A x = A^T y，A 每行 [r,g,b,1]
    final List<List<double>> ata = <List<double>>[
      <double>[0, 0, 0, 0],
      <double>[0, 0, 0, 0],
      <double>[0, 0, 0, 0],
      <double>[0, 0, 0, 0],
    ];
    final List<double> aty = <double>[0, 0, 0, 0];
    for (int i = 0; i < n; i++) {
      final List<double> row = <double>[
        measured[i][0],
        measured[i][1],
        measured[i][2],
        1.0,
      ];
      final double y = reference[i][channel];
      for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
          ata[r][c] += row[r] * row[c];
        }
        aty[r] += row[r] * y;
      }
    }
    for (int i = 0; i < 4; i++) {
      ata[i][i] += ridge;
    }
    final List<double> solved = Homography._solve(ata, aty);
    matrix[channel * 3 + 0] = solved[0];
    matrix[channel * 3 + 1] = solved[1];
    matrix[channel * 3 + 2] = solved[2];
    offset[channel] = solved[3];
  }

  // 计算残差
  double sum = 0;
  double maxDelta = 0;
  final CameraCcm ccm =
      CameraCcm(matrix: matrix, offset: offset);
  for (int i = 0; i < n; i++) {
    final List<double> fixed = ccm.apply(measured[i]);
    final double d = deltaE00(
      rgbToLab(
        linearToSrgb(fixed[0]),
        linearToSrgb(fixed[1]),
        linearToSrgb(fixed[2]),
      ),
      rgbToLab(
        linearToSrgb(reference[i][0]),
        linearToSrgb(reference[i][1]),
        linearToSrgb(reference[i][2]),
      ),
    );
    sum += d;
    if (d > maxDelta) maxDelta = d;
  }

  return CameraCcm(
    matrix: matrix,
    offset: offset,
    meanDelta: sum / n,
    maxDelta: maxDelta,
  );
}

/// 把一张图按 CCM 校正（线性光里做，再编码回去）。
img.Image applyCcm(img.Image source, CameraCcm ccm) {
  final img.Image out = source.clone();
  for (final img.Pixel p in out) {
    final List<double> linear = ccm.apply(<double>[
      srgbToLinear(p.r.toInt()),
      srgbToLinear(p.g.toInt()),
      srgbToLinear(p.b.toInt()),
    ]);
    p.r = linearToSrgb(linear[0]);
    p.g = linearToSrgb(linear[1]);
    p.b = linearToSrgb(linear[2]);
  }
  return out;
}

/// 从「已经摆正的色卡图」+ 四个角点算出 CCM。
///
/// 采样时每块取中心 60% 区域的平均色，避免边缘过渡与网格线。
CameraCcm calibrateColorCard(img.Image image, List<Offset2> quad) {
  final Homography h = Homography.fromQuad(quad);
  final List<List<double>> measured = <List<double>>[];
  final List<List<double>> reference = <List<double>>[];

  for (int row = 0; row < ColorChecker.rows; row++) {
    for (int col = 0; col < ColorChecker.columns; col++) {
      final double u = (col + 0.5) / ColorChecker.columns;
      final double v = (row + 0.5) / ColorChecker.rows;
      final double du = 0.3 / ColorChecker.columns;
      final double dv = 0.3 / ColorChecker.rows;

      final Offset2 p00 = h.map(u - du, v - dv);
      final Offset2 p10 = h.map(u + du, v - dv);
      final Offset2 p01 = h.map(u - du, v + dv);
      final Offset2 p11 = h.map(u + du, v + dv);

      final int x1 = <double>[p00.x, p10.x, p01.x, p11.x]
          .reduce(math.min)
          .round()
          .clamp(0, image.width - 1);
      final int x2 = <double>[p00.x, p10.x, p01.x, p11.x]
          .reduce(math.max)
          .round()
          .clamp(x1 + 1, image.width);
      final int y1 = <double>[p00.y, p10.y, p01.y, p11.y]
          .reduce(math.min)
          .round()
          .clamp(0, image.height - 1);
      final int y2 = <double>[p00.y, p10.y, p01.y, p11.y]
          .reduce(math.max)
          .round()
          .clamp(y1 + 1, image.height);

      final WhitePoint avg = sampleAverage(image, x1, y1, x2 - x1, y2 - y1);
      final List<int> ref =
          ColorChecker.srgb[row * ColorChecker.columns + col];
      measured.add(<double>[
        srgbToLinear(avg.r.round()),
        srgbToLinear(avg.g.round()),
        srgbToLinear(avg.b.round()),
      ]);
      reference.add(<double>[
        srgbToLinear(ref[0]),
        srgbToLinear(ref[1]),
        srgbToLinear(ref[2]),
      ]);
    }
  }
  return fitCcm(measured, reference);
}

/// 相机校色的本地存储：一个 JSON 文件，跟着 App 的文档目录走。
class CameraProfile {
  CameraProfile._();

  static const String fileName = 'camera_profile.json';

  /// 配置文件位置（页面要显示「保存于 …」会读它的修改时间）。
  static Future<File> file() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, fileName));
  }

  static Future<CameraCcm?> load() async {
    try {
      final File f = await file();
      if (!await f.exists()) return null;
      final Object? json = jsonDecode(await f.readAsString());
      if (json is Map<String, Object?>) return CameraCcm.fromJson(json);
      if (json is Map) return CameraCcm.fromJson(json.cast<String, Object?>());
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(CameraCcm? ccm) async {
    final File f = await file();
    if (ccm == null) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.writeAsString(jsonEncode(ccm.toJson()));
  }
}
