import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'calibration.dart';
import 'ccm.dart';
import 'compare.dart';

/// 图像重活全都在后台 isolate 里做。
///
/// 约定：入参和返回值只用「可跨 isolate 传输」的类型（Map / List / String /
/// int / double / Uint8List），不用自定义类。
///
/// 注意：**标定不生成「校正后的照片」**。白点只是测出来的一个数值，
/// 家里那张作为基准永远保持原样，工地那张在「对比」时临时拉到家里的白点。
const int kPreviewSide = 1200; // 标定页预览/采样用的长边
const int kReportSide = 1200; // 导出拼图每张的长边

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

double _num(Map<Object?, Object?> map, String key) =>
    (map[key]! as num).toDouble();

int? _intOrNull(Map<Object?, Object?> map, String key) {
  final Object? v = map[key];
  return v == null ? null : (v as num).toInt();
}

/// 可选相机色彩校正（CCM）：作用在两张图的线性光空间，先校色再拉白点。
CameraCcm? _ccmOf(Object? raw) {
  if (raw is! List || raw.length != 12) return null;
  final List<double> values =
      raw.map((Object? v) => (v! as num).toDouble()).toList();
  return CameraCcm(
      matrix: values.sublist(0, 9), offset: values.sublist(9, 12));
}

/// 批量对比：**参照图只解码一次**，然后依次处理每个目标。
///
/// 以前每个目标各调一次 compute，3 个目标就把参照图解码 3 遍；
/// 现在一次调用处理整批，最后一次性回传所有「拉平后」的图。
List<Object?> _compareMany(Map<String, Object?> arg) {
  final String refPath = arg['ref']! as String;
  final double rr = (arg['refR']! as num).toDouble();
  final double rg = (arg['refG']! as num).toDouble();
  final double rb = (arg['refB']! as num).toDouble();
  final int? rcr = arg['refCheckR'] as int?;
  final int? rcg = arg['refCheckG'] as int?;
  final int? rcb = arg['refCheckB'] as int?;
  final List<Object?> targets = arg['targets']! as List<Object?>;
  final CameraCcm? ccm = _ccmOf(arg['ccm']);

  final img.Image? refRaw = decodeOriented(File(refPath).readAsBytesSync());
  if (refRaw == null) {
    throw const FormatException('参照图无法解码');
  }
  img.Image ref = downscale(refRaw);
  if (ccm != null) ref = applyCcm(ref, ccm);
  final WhitePoint referenceWhite = WhitePoint(rr, rg, rb);
  final WhitePoint? referenceChecker =
      (rcr != null && rcg != null && rcb != null)
          ? WhitePoint(rcr.toDouble(), rcg.toDouble(), rcb.toDouble())
          : null;

  final List<Object?> results = <Object?>[];
  for (final Object? item in targets) {
    final Map<Object?, Object?> t = item! as Map<Object?, Object?>;
    final String path = t['path']! as String;
    try {
      final img.Image? target = decodeOriented(File(path).readAsBytesSync());
      if (target == null) throw const FormatException('目标图无法解码');

      img.Image scaled = downscale(target);
      if (ccm != null) scaled = applyCcm(scaled, ccm);

      final int? tcr = _intOrNull(t, 'checkR');
      final int? tcg = _intOrNull(t, 'checkG');
      final int? tcb = _intOrNull(t, 'checkB');
      final WhitePoint? targetChecker =
          (tcr != null && tcg != null && tcb != null)
              ? WhitePoint(tcr.toDouble(), tcg.toDouble(), tcb.toDouble())
              : null;

      final CompareResult result = compareToReference(
        reference: ref,
        targetRaw: scaled,
        referenceWhite: referenceWhite,
        targetWhite: WhitePoint(_num(t, 'r'), _num(t, 'g'), _num(t, 'b')),
        referenceChecker: referenceChecker,
        targetChecker: targetChecker,
      );

      results.add(<String, Object?>{
        'id': t['id'],
        'ok': true,
        'jpeg': img.encodeJpg(result.processed, quality: 92),
        'deltaE': result.deltaEAfter,
        'deltaEBefore': result.deltaEBefore,
        'errorFloor': result.errorFloor ?? 0.0,
        'trustworthy': result.trustworthy,
      });
    } catch (error) {
      results.add(<String, Object?>{
        'id': t['id'],
        'ok': false,
        'error': error.toString(),
      });
    }
  }
  return results;
}

// ---------------------------------------------------------------- 对外接口

Future<Uint8List> decodePreviewBytes(Uint8List bytes,
        {int maxSide = kPreviewSide}) =>
    compute(_decodePreview, <String, Object?>{
      'bytes': bytes,
      'maxSide': maxSide,
    });

class CompareOutcome {
  const CompareOutcome({
    required this.targetId,
    required this.ok,
    this.jpeg,
    this.deltaE = 0,
    this.deltaEBefore = 0,
    this.errorFloor = 0,
    this.trustworthy = 0,
    this.error,
  });

  final String targetId;
  final bool ok;
  final Uint8List? jpeg;
  final double deltaE;
  final double deltaEBefore;
  final double errorFloor;
  final double trustworthy;
  final String? error;

  bool get hasFloor => errorFloor > 0;
}

/// 一次对比请求（单个目标）。
class CompareTask {
  const CompareTask({
    required this.targetId,
    required this.path,
    required this.whiteR,
    required this.whiteG,
    required this.whiteB,
    this.checkR,
    this.checkG,
    this.checkB,
  });

  final String targetId;
  final String path;
  final int whiteR;
  final int whiteG;
  final int whiteB;
  final int? checkR;
  final int? checkG;
  final int? checkB;

  Map<String, Object?> toMap() => <String, Object?>{
        'id': targetId,
        'path': path,
        'r': whiteR,
        'g': whiteG,
        'b': whiteB,
        'checkR': checkR,
        'checkG': checkG,
        'checkB': checkB,
      };
}

/// 批量对比：一次 isolate 调用处理所有目标（参照图只解码一遍）。
Future<List<CompareOutcome>> compareMany({
  required String referencePath,
  required int referenceR,
  required int referenceG,
  required int referenceB,
  int? referenceCheckR,
  int? referenceCheckG,
  int? referenceCheckB,
  required List<CompareTask> tasks,
  List<double>? ccm,
}) async {
  if (tasks.isEmpty) return <CompareOutcome>[];
  final List<Object?> raw = await compute(_compareMany, <String, Object?>{
    'ref': referencePath,
    'refR': referenceR,
    'refG': referenceG,
    'refB': referenceB,
    'refCheckR': referenceCheckR,
    'refCheckG': referenceCheckG,
    'refCheckB': referenceCheckB,
    'targets': tasks.map((CompareTask t) => t.toMap()).toList(),
    'ccm': ccm,
  });
  return raw.map((Object? item) {
    final Map<Object?, Object?> m = item! as Map<Object?, Object?>;
    final bool ok = m['ok'] == true;
    return CompareOutcome(
      targetId: m['id']! as String,
      ok: ok,
      jpeg: ok ? m['jpeg']! as Uint8List : null,
      deltaE: ok ? _num(m, 'deltaE') : 0,
      deltaEBefore: ok ? _num(m, 'deltaEBefore') : 0,
      errorFloor: ok ? _num(m, 'errorFloor') : 0,
      trustworthy: ok ? _num(m, 'trustworthy') : 0,
      error: ok ? null : m['error'] as String?,
    );
  }).toList();
}
