/// 数据模型：一次对比 = 一个 session，里面至少两张 capture（参照 + 目标），
/// 外加一条 comparison（处理结果）。

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
    this.calibratedPath,
    this.whiteR,
    this.whiteG,
    this.whiteB,
    this.calibrationMethod = 'none',
  });

  final String id;
  final String sessionId;

  /// 'reference'（家里，默认基准）或 'target'（厂里 / 其他环境）
  final String role;
  final String imagePath;
  final String source; // camera / upload
  final String location;
  final String? calibratedPath;
  final int? whiteR;
  final int? whiteG;
  final int? whiteB;
  final String calibrationMethod; // none / white_patch / gray_card / color_checker
  final DateTime createdAt;

  bool get isReference => role == 'reference';
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
    this.note = '',
  });

  final String id;
  final String sessionId;
  final String referenceCaptureId;
  final String targetCaptureId;

  /// 把目标图拉到参照基准后的成品图。
  final String processedPath;

  /// 主色块平均 ΔE00（越小越接近）。
  final double deltaE;
  final String note;
  final DateTime createdAt;
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

  /// 可以有多张目标图（多对一对比）。
  final List<Capture> targets;

  /// targetCaptureId -> 对比结果
  final Map<String, Comparison> comparisons;

  Capture? get target => targets.isEmpty ? null : targets.first;

  Comparison? comparisonFor(String targetId) => comparisons[targetId];

  int get comparedCount => comparisons.length;
}
