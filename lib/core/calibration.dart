import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 白点（某个「已知应该是白色」区域的平均 RGB，0-255 浮点）。
class WhitePoint {
  const WhitePoint(this.r, this.g, this.b);

  final double r;
  final double g;
  final double b;

  /// 低于这个亮度说明用户框到了阴影/深色物体，增益会爆炸。
  static const double minUsable = 8;

  bool get isValid => r >= minUsable && g >= minUsable && b >= minUsable;

  double get luminance => 0.2126 * r + 0.7152 * g + 0.0722 * b;

  /// 三通道里最暗的那个，用来判断「这块白是否偏色到没法用」。
  double get minChannel => math.min(r, math.min(g, b));

  /// 通道间最大差异（近似色偏量）。
  double get chromaSpread =>
      math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));

  @override
  String toString() =>
      '(${r.toStringAsFixed(0)}, ${g.toStringAsFixed(0)}, ${b.toStringAsFixed(0)})';
}

/// sRGB(0-255) -> 线性光(0-1) 的 256 项查表。
final Float64List _srgbToLinear = Float64List.fromList(
  List<double>.generate(256, (int i) {
    final double c = i / 255.0;
    return c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }),
);

/// 线性光(0-1) -> sRGB(0-255)。用 1024 项查表 + 线性插值，避免逐像素 pow。
final Float64List _linearToSrgb = () {
  final Float64List table = Float64List(1025);
  for (int i = 0; i <= 1024; i++) {
    final double c = i / 1024.0;
    final double v = c <= 0.0031308
        ? 12.92 * c
        : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
    table[i] = (v * 255.0).clamp(0.0, 255.0);
  }
  return table;
}();

/// 公开给 CCM 用的线性/编码互转（和内部查表同一套数值）。
double srgbToLinear(int v) => _srgbToLinear[v.clamp(0, 255)];

int linearToSrgb(double linear) => _encodeSrgb(linear);

int _encodeSrgb(double linear) {
  if (linear <= 0) return 0;
  if (linear >= 1) return 255;
  final double pos = linear * 1024.0;
  final int i = pos.floor();
  final double f = pos - i;
  final double v = _linearToSrgb[i] * (1 - f) + _linearToSrgb[i + 1] * f;
  return v.round().clamp(0, 255);
}

/// 白平衡增益上下限。
///
/// 上限不能太紧：室内拍的白纸经常只有 100-150，白点 100 就需要 7.85 倍增益才能到 255，
/// 卡在 4 倍会导致「标定完白纸还是灰的」（就踩过这个坑）。
/// 取 12 倍：白点低到 60 还能拉到 205，再暗的框选本身就该被拒（见 WhitePoint.minUsable）。
const double kMinGain = 0.1;
const double kMaxGain = 12.0;

/// 在图上取一个矩形区域的平均色（用于框选白纸 / 灰卡）。
///
/// [stride] 每隔多少像素采样一次：拖动过程中用 4/8 降采样，松手后再用 1 精算。
WhitePoint sampleAverage(img.Image image, int x, int y, int w, int h,
    {int stride = 1}) {
  final int step = stride < 1 ? 1 : stride;
  final int x1 = x.clamp(0, image.width - 1);
  final int y1 = y.clamp(0, image.height - 1);
  final int x2 = (x + w).clamp(x1 + 1, image.width);
  final int y2 = (y + h).clamp(y1 + 1, image.height);

  double sr = 0;
  double sg = 0;
  double sb = 0;
  int count = 0;
  for (int py = y1; py < y2; py += step) {
    for (int px = x1; px < x2; px += step) {
      final img.Pixel p = image.getPixel(px, py);
      sr += p.r;
      sg += p.g;
      sb += p.b;
      count++;
    }
  }
  if (count == 0) return const WhitePoint(0, 0, 0);
  return WhitePoint(sr / count, sg / count, sb / count);
}

/// 框内亮度的 P5–P95 跨度（越小说明这块白越均匀）。用 [stride] 降采样。
double luminanceSpread(img.Image image, int x, int y, int w, int h,
    {int stride = 2}) {
  final int step = stride < 1 ? 1 : stride;
  final int x1 = x.clamp(0, image.width - 1);
  final int y1 = y.clamp(0, image.height - 1);
  final int x2 = (x + w).clamp(x1 + 1, image.width);
  final int y2 = (y + h).clamp(y1 + 1, image.height);
  final List<int> lum = <int>[];
  for (int py = y1; py < y2; py += step) {
    for (int px = x1; px < x2; px += step) {
      final img.Pixel p = image.getPixel(px, py);
      lum.add((0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b).round());
    }
  }
  if (lum.length < 5) return 0;
  lum.sort();
  final int lo = lum[((lum.length - 1) * 0.05).floor()];
  final int hi = lum[((lum.length - 1) * 0.95).floor()];
  return (hi - lo).toDouble();
}

/// 增益必须在**线性光**里算。
///
/// 如果在 sRGB 数值上算（255/200=1.275）再乘到线性值上，白点 200 只会被拉到 223，
/// 而不是宣称的 255 —— gamma 编码是凹函数，两种算法差得很明显。
/// 正确做法：lin(目标) / lin(白点)，用在线性光上刚好把白点落在目标值。
double _linearGain(double target, double white) {
  final double w = _srgbToLinear[white.round().clamp(0, 255)];
  if (w <= 1e-6) return kMaxGain;
  final double t = _srgbToLinear[target.round().clamp(0, 255)];
  return (t / w).clamp(kMinGain, kMaxGain);
}

/// 把整张图的白点拉到 [target]（默认 255）：每个通道乘一个增益。
///
/// **在线性光空间做**：sRGB 是 gamma 编码的，直接乘数字相当于改了 gamma，
/// 会偏色。正确顺序是 sRGB -> 线性 -> 乘增益 -> 回 sRGB。
img.Image applyWhiteBalance(img.Image source,
    {required WhitePoint white, double target = 255}) {
  final img.Image out = source.clone();
  if (!white.isValid) return out;

  final double gr = _linearGain(target, white.r);
  final double gg = _linearGain(target, white.g);
  final double gb = _linearGain(target, white.b);

  for (final img.Pixel p in out) {
    p.r = _encodeSrgb(_srgbToLinear[p.r.toInt().clamp(0, 255)] * gr);
    p.g = _encodeSrgb(_srgbToLinear[p.g.toInt().clamp(0, 255)] * gg);
    p.b = _encodeSrgb(_srgbToLinear[p.b.toInt().clamp(0, 255)] * gb);
  }
  return out;
}

/// 把图的 [from] 白点映射到 [to] 白点（用于「把厂里拉成家里」）。
///
/// 不是把两边都拉纯白，而是保留参照方的白点，让目标方「看起来像在参照环境里」。
img.Image transferWhite(img.Image source,
    {required WhitePoint from, required WhitePoint to}) {
  final img.Image out = source.clone();
  if (!from.isValid || !to.isValid) return out;

  // 相对增益同样要夹在合理范围内：参照极亮、目标极暗时不至于把目标拉爆。
  final double gr = _linearGain(to.r, from.r);
  final double gg = _linearGain(to.g, from.g);
  final double gb = _linearGain(to.b, from.b);

  for (final img.Pixel p in out) {
    p.r = _encodeSrgb(_srgbToLinear[p.r.toInt().clamp(0, 255)] * gr);
    p.g = _encodeSrgb(_srgbToLinear[p.g.toInt().clamp(0, 255)] * gg);
    p.b = _encodeSrgb(_srgbToLinear[p.b.toInt().clamp(0, 255)] * gb);
  }
  return out;
}

/// 把某个颜色按「白点迁移」的同一套增益搬过去（用于「已知物自检」）。
///
/// 迁移图像和迁移单个颜色必须用完全相同的公式，否则误差下限就没意义。
WhitePoint migrateColor(
  WhitePoint color, {
  required WhitePoint from,
  required WhitePoint to,
}) {
  if (!from.isValid || !to.isValid) return color;
  final double gr = _linearGain(to.r, from.r);
  final double gg = _linearGain(to.g, from.g);
  final double gb = _linearGain(to.b, from.b);
  return WhitePoint(
    _encodeSrgb(_srgbToLinear[color.r.round().clamp(0, 255)] * gr).toDouble(),
    _encodeSrgb(_srgbToLinear[color.g.round().clamp(0, 255)] * gg).toDouble(),
    _encodeSrgb(_srgbToLinear[color.b.round().clamp(0, 255)] * gb).toDouble(),
  );
}

/// 解码 + 按 EXIF 摆正（手机竖拍时像素是横的，不摆正会「框到的白纸和采样到的位置」不一致）。
img.Image? decodeOriented(Uint8List bytes) {
  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return img.bakeOrientation(decoded);
}

/// 缩放，控制处理耗时（对比不需要原图分辨率）。
img.Image downscale(img.Image source, {int maxSide = 1400}) {
  final int longest = math.max(source.width, source.height);
  if (longest <= maxSide) return source.clone();
  final double ratio = maxSide / longest;
  return img.copyResize(
    source,
    width: (source.width * ratio).round(),
    height: (source.height * ratio).round(),
    interpolation: img.Interpolation.linear,
  );
}

/// RGB -> Lab（sRGB, D65）。
List<double> rgbToLab(int r, int g, int b) {
  final double rl = _srgbToLinear[r.clamp(0, 255)];
  final double gl = _srgbToLinear[g.clamp(0, 255)];
  final double bl = _srgbToLinear[b.clamp(0, 255)];

  final double x = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375;
  final double y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750;
  final double z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041;

  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : (7.787 * t + 16 / 116);

  final double fx = f(x / 0.95047);
  final double fy = f(y / 1.00000);
  final double fz = f(z / 1.08883);

  return <double>[116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

/// CIEDE2000 色差。
double deltaE00(List<double> lab1, List<double> lab2) {
  final double l1 = lab1[0], a1 = lab1[1], b1 = lab1[2];
  final double l2 = lab2[0], a2 = lab2[1], b2 = lab2[2];

  final double c1 = math.sqrt(a1 * a1 + b1 * b1);
  final double c2 = math.sqrt(a2 * a2 + b2 * b2);
  final double cb = (c1 + c2) / 2;

  final double g = 0.5 *
      (1 -
          math.sqrt(math.pow(cb, 7) / (math.pow(cb, 7) + math.pow(25, 7))));

  final double a1p = (1 + g) * a1;
  final double a2p = (1 + g) * a2;
  final double c1p = math.sqrt(a1p * a1p + b1 * b1);
  final double c2p = math.sqrt(a2p * a2p + b2 * b2);

  double hp(double ap, double bp) {
    if (ap == 0 && bp == 0) return 0;
    final double angle = math.atan2(bp, ap) * 180 / math.pi;
    return angle < 0 ? angle + 360 : angle;
  }

  final double h1p = hp(a1p, b1);
  final double h2p = hp(a2p, b2);

  final double dlp = l2 - l1;
  final double dcp = c2p - c1p;

  double dhp = 0;
  if (c1p * c2p != 0) {
    dhp = h2p - h1p;
    if (dhp > 180) dhp -= 360;
    if (dhp < -180) dhp += 360;
  }
  final double dHp = 2 * math.sqrt(c1p * c2p) * math.sin(dhp * math.pi / 360);

  final double lbp = (l1 + l2) / 2;
  final double cbp = (c1p + c2p) / 2;

  double hbp;
  if (c1p * c2p == 0) {
    hbp = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180) {
    hbp = (h1p + h2p) / 2;
  } else {
    hbp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
  }

  final double t = 1 -
      0.17 * math.cos((hbp - 30) * math.pi / 180) +
      0.24 * math.cos(2 * hbp * math.pi / 180) +
      0.32 * math.cos((3 * hbp + 6) * math.pi / 180) -
      0.20 * math.cos((4 * hbp - 63) * math.pi / 180);

  final double sl = 1 +
      0.015 * math.pow(lbp - 50, 2) / math.sqrt(20 + math.pow(lbp - 50, 2));
  final double sc = 1 + 0.045 * cbp;
  final double sh = 1 + 0.015 * cbp * t;

  final double rt = -2 *
      math.sqrt(math.pow(cbp, 7) / (math.pow(cbp, 7) + math.pow(25, 7))) *
      math.sin(60 * math.exp(-math.pow((hbp - 275) / 25, 2)) * math.pi / 180);

  final double dl = dlp / sl;
  final double dc = dcp / sc;
  final double dh = dHp / sh;

  return math.sqrt(dl * dl + dc * dc + dh * dh + rt * dc * dh);
}

/// 直接算两个 RGB 的 ΔE00（UI/测试用）。
double deltaE00Rgb(int r1, int g1, int b1, int r2, int g2, int b2) =>
    deltaE00(rgbToLab(r1, g1, b1), rgbToLab(r2, g2, b2));
