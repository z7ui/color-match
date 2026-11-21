import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'calibration.dart';
import 'compare.dart';

/// 图像重活全都在后台 isolate 里做。
///
/// 之前解码、逐像素白平衡、JPEG 编码、拼图、导出全都跑在 UI 线程上：
/// 一张 12MP 的照片就能卡 1-2 秒，批量对比基本必 ANR。
///
/// 约定：入参和返回值只用「可跨 isolate 传输」的类型
/// （Map / List / String / int / double / Uint8List），不用自定义类。
const int kWorkSide = 1600; // 存储用的工作副本长边
const int kPreviewSide = 1200; // 标定页预览/采样用的长边
const int kCompareSide = 1400; // 对比计算用的长边（与 downscale 默认值一致）
const int kReportSide = 1000; // 导出拼图每张的长边

/// 把手机原图解码、按 EXIF 摆正、缩到预览尺寸，返回 JPEG 字节。
Uint8List _decodePreview(Map<String, Object?> arg) {
  final Uint8List bytes = arg['bytes']! as Uint8List;
  final int maxSide = (arg['maxSide'] as int?) ?? kPreviewSide;
  final img.Image? decoded = decodeOriented(bytes);
  if (decoded == null) {
    throw const FormatException('图片无法解码');
  }
  final img.Image small = downscale(decoded, maxSide: maxSide);
  return img.encodeJpg(small, quality: 88);
}

/// 标定：解码原图 -> 缩到工作尺寸 -> 白平衡 -> JPEG 字节。
Uint8List _calibrate(Map<String, Object?> arg) {
  final Uint8List bytes = arg['bytes']! as Uint8List;
  final double r = (arg['r']! as num).toDouble();
  final double g = (arg['g']! as num).toDouble();
  final double b = (arg['b']! as num).toDouble();
  final img.Image? decoded = decodeOriented(bytes);
  if (decoded == null) {
    throw const FormatException('图片无法解码');
  }
  final img.Image work = downscale(decoded, maxSide: kWorkSide);
  final img.Image fixed =
      applyWhiteBalance(work, white: WhitePoint(r, g, b));
  return img.encodeJpg(fixed, quality: 92);
}

/// 一次对比：读三张图 -> 算 ΔE -> 输出「拉平后」的 JPEG。
Map<String, Object?> _compare(Map<String, Object?> arg) {
  final String refRawPath = arg['refRaw']! as String;
  final String refCalPath = arg['refCal']! as String;
  final String targetPath = arg['target']! as String;
  final double rr = (arg['refR']! as num).toDouble();
  final double rg = (arg['refG']! as num).toDouble();
  final double rb = (arg['refB']! as num).toDouble();
  final double tr = (arg['targetR']! as num).toDouble();
  final double tg = (arg['targetG']! as num).toDouble();
  final double tb = (arg['targetB']! as num).toDouble();

  final img.Image? refRaw =
      decodeOriented(File(refRawPath).readAsBytesSync());
  final img.Image? refCal =
      decodeOriented(File(refCalPath).readAsBytesSync());
  final img.Image? target =
      decodeOriented(File(targetPath).readAsBytesSync());
  if (refRaw == null || refCal == null || target == null) {
    throw const FormatException('图片无法解码');
  }

  final CompareResult result = compareToReference(
    referenceRaw: downscale(refRaw),
    referenceCalibrated: downscale(refCal),
    targetRaw: downscale(target),
    referenceWhite: WhitePoint(rr, rg, rb),
    targetWhite: WhitePoint(tr, tg, tb),
  );

  return <String, Object?>{
    'jpeg': img.encodeJpg(result.processed, quality: 92),
    'deltaE': result.deltaEAfter,
    'deltaEBefore': result.deltaEBefore,
    'improvement': result.improvement,
  };
}

/// 导出报告：每行「参照 | 目标原图 | 目标校正后」+ 一行 ASCII 标签。
Uint8List _report(Map<String, Object?> arg) {
  final String refPath = arg['ref']! as String;
  final List<Object?> rows = arg['rows']! as List<Object?>;

  final img.Image? refImage =
      decodeOriented(File(refPath).readAsBytesSync());
  if (refImage == null) {
    throw const FormatException('参照图无法解码');
  }
  final img.Image ref = downscale(refImage, maxSide: kReportSide);

  final List<img.Image> built = <img.Image>[];
  for (final Object? item in rows) {
    final Map<Object?, Object?> row = item! as Map<Object?, Object?>;
    final img.Image? before =
        decodeOriented(File(row['before']! as String).readAsBytesSync());
    final img.Image? after =
        decodeOriented(File(row['after']! as String).readAsBytesSync());
    if (before == null || after == null) continue;
    built.add(buildRow(
      reference: ref,
      before: downscale(before, maxSide: kReportSide),
      after: downscale(after, maxSide: kReportSide),
      label: (row['label'] as String?) ?? '',
    ));
  }
  return img.encodeJpg(buildVerticalReport(built), quality: 92);
}

// ---------------------------------------------------------------- 对外接口

Future<Uint8List> decodePreviewBytes(Uint8List bytes,
        {int maxSide = kPreviewSide}) =>
    compute(_decodePreview, <String, Object?>{'bytes': bytes, 'maxSide': maxSide});

Future<Uint8List> calibrateBytes(
  Uint8List bytes, {
  required double r,
  required double g,
  required double b,
}) =>
    compute(_calibrate, <String, Object?>{'bytes': bytes, 'r': r, 'g': g, 'b': b});

class CompareOutcome {
  const CompareOutcome({
    required this.jpeg,
    required this.deltaE,
    required this.deltaEBefore,
    required this.improvement,
  });

  final Uint8List jpeg;
  final double deltaE;
  final double deltaEBefore;
  final double improvement;
}

Future<CompareOutcome> compareFiles({
  required String referenceRawPath,
  required String referenceCalibratedPath,
  required String targetPath,
  required int refR,
  required int refG,
  required int refB,
  required int targetR,
  required int targetG,
  required int targetB,
}) async {
  final Map<String, Object?> out = await compute(_compare, <String, Object?>{
    'refRaw': referenceRawPath,
    'refCal': referenceCalibratedPath,
    'target': targetPath,
    'refR': refR,
    'refG': refG,
    'refB': refB,
    'targetR': targetR,
    'targetG': targetG,
    'targetB': targetB,
  });
  return CompareOutcome(
    jpeg: out['jpeg']! as Uint8List,
    deltaE: (out['deltaE']! as num).toDouble(),
    deltaEBefore: (out['deltaEBefore']! as num).toDouble(),
    improvement: (out['improvement']! as num).toDouble(),
  );
}

Future<Uint8List> buildReportBytes({
  required String referencePath,
  required List<Map<String, Object?>> rows,
}) =>
    compute(_report, <String, Object?>{'ref': referencePath, 'rows': rows});
