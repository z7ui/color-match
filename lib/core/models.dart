import 'dart:math' as math;

// 数据模型：一次对比 = 一个 session，里面至少两张 capture（参照 + 目标），
// 外加一条 comparison（处理结果）。

class CompareSession {
  const CompareSession({
    required this.id,
    required this.name,
    required this.createdAt,
    this.note = '',
  });

  final String id;
  final String name;
  final String note;
  final DateTime createdAt;

  CompareSession copyWith({String? name, String? note}) {
    return CompareSession(
      id: id,
      name: name ?? this.name,
      note: note ?? this.note,
      createdAt: createdAt,
    );
  }
}

class Capture {
  const Capture({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.imagePath,
    required this.source,
    required this.createdAt,
    this.location = '',
    this.whiteR,
    this.whiteG,
    this.whiteB,
    this.calibrationMethod = 'none',
    this.checkR,
    this.checkG,
    this.checkB,
    this.usedTorch = false,
  });

  final String id;
  final String sessionId;

  /// 'reference'（家里，基准）或 'target'（厂里 / 别的环境）
  final String role;
  final String imagePath;
  final String source; // camera / upload

  /// 在哪拍的 / 什么光（多光源复检用）
  final String location;
  final int? whiteR;
  final int? whiteG;
  final int? whiteB;
  final String calibrationMethod; // none / white_patch / color_checker

  /// 可选：同一张图里另标的一块「已知物」的颜色（自检用）
  final int? checkR;
  final int? checkG;
  final int? checkB;

  /// 拍这张时有没有开补光（手电筒常亮）
  final bool usedTorch;

  final DateTime createdAt;

  bool get isReference => role == 'reference';
  bool get isCalibrated => whiteR != null && whiteG != null && whiteB != null;
  bool get hasChecker => checkR != null && checkG != null && checkB != null;

  String get shortId => id.length >= 4 ? id.substring(0, 4) : id;
}

class Comparison {
  const Comparison({
    required this.id,
    required this.sessionId,
    required this.referenceCaptureId,
    required this.targetCaptureId,
    required this.processedPath,
    required this.deltaE,
    required this.createdAt,
    this.deltaEBefore = 0,
    this.note = '',
    this.errorFloor = 0,
  });

  final String id;
  final String sessionId;
  final String referenceCaptureId;
  final String targetCaptureId;
  final String processedPath;

  /// 校正后 ΔE00（越小越接近）
  final double deltaE;

  /// 校正前 ΔE00（两张原始照片直接比）
  final double deltaEBefore;

  /// 误差下限（0 表示没标已知物，量不出来）
  final double errorFloor;

  final String note;
  final DateTime createdAt;

  double get improvement {
    if (deltaEBefore <= 0.01) return 0;
    return ((deltaEBefore - deltaE) / deltaEBefore).clamp(0.0, 1.0);
  }

  bool get hasErrorFloor => errorFloor > 0;

  /// 扣掉误差下限后的可信差异
  double get trustworthy {
    if (errorFloor <= 0) return deltaE;
    final double v = deltaE * deltaE - errorFloor * errorFloor;
    return v <= 0 ? 0 : math.sqrt(v);
  }
}

/// 详情页用：session + 参照图 + 多张目标图 + 对比结果。
class SessionDetail {
  const SessionDetail({
    required this.session,
    required this.reference,
    required this.targets,
    this.comparisons = const <String, Comparison>{},
  });

  final CompareSession session;
  final Capture? reference;
  final List<Capture> targets;

  /// targetCaptureId -> 对比结果
  final Map<String, Comparison> comparisons;

  Comparison? comparisonFor(String targetId) => comparisons[targetId];

  int get comparedCount => comparisons.length;

  int get pendingCount => targets
      .where((Capture t) => t.isCalibrated && !comparisons.containsKey(t.id))
      .length;
}
