import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// 白点（某个「已知应该是白色」区域的平均 RGB）。
class WhitePoint {
  const WhitePoint(this.r, this.g, this.b);

  final double r;
  final double g;
  final double b;

  bool get isValid => r > 2 && g > 2 && b > 2;

  double get luminance => 0.2126 * r + 0.7152 * g + 0.0722 * b;

  @override
  String toString() =>
      '(${r.toStringAsFixed(0)}, ${g.toStringAsFixed(0)}, ${b.toStringAsFixed(0)})';
}

/// 在图上取一个矩形区域的平均色（用于框选白纸 / 灰卡）。
WhitePoint sampleAverage(img.Image image, int x, int y, int w, int h) {
  final int x1 = x.clamp(0, image.width - 1);
  final int y1 = y.clamp(0, image.height - 1);
  final int x2 = (x + w).clamp(x1 + 1, image.width);
  final int y2 = (y + h).clamp(y1 + 1, image.height);

  double sr = 0;
  double sg = 0;
  double sb = 0;
  int count = 0;
  for (int py = y1; py < y2; py++) {
    for (int px = x1; px < x2; px++) {
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

/// 把整张图的白点拉到 [target]（默认 255）：每个通道乘一个增益。
///
/// 这是「穷人版」校准：一张白纸 / 灰卡就够，不需要色卡。
img.Image applyWhiteBalance(img.Image source,
    {required WhitePoint white, double target = 255}) {
  final img.Image out = source.clone();
  if (!white.isValid) return out;

  final double gr = target / white.r;
  final double gg = target / white.g;
  final double gb = target / white.b;

  for (final img.Pixel p in out) {
    p.r = (p.r * gr).clamp(0, 255);
    p.g = (p.g * gg).clamp(0, 255);
    p.b = (p.b * gb).clamp(0, 255);
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

  final double gr = to.r / from.r;
  final double gg = to.g / from.g;
  final double gb = to.b / from.b;

  for (final img.Pixel p in out) {
    p.r = (p.r * gr).clamp(0, 255);
    p.g = (p.g * gg).clamp(0, 255);
    p.b = (p.b * gb).clamp(0, 255);
  }
  return out;
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
    interpolation: img.Interpolation.average,
  );
}

/// RGB -> Lab（sRGB, D65）。
List<double> rgbToLab(int r, int g, int b) {
  double lin(double v) {
    final double c = v / 255.0;
    return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  final double rl = lin(r.toDouble());
  final double gl = lin(g.toDouble());
  final double bl = lin(b.toDouble());

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

  double hbp = h1p + h2p;
  if (c1p * c2p != 0) {
    if ((h1p - h2p).abs() > 180) {
      hbp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
    } else {
      hbp = (h1p + h2p) / 2;
    }
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
