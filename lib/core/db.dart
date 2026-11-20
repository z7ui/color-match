import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'config.dart';
import 'models.dart';

/// 本地 SQLite：会话、采集、对比结果。
class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  Database? _db;

  Future<Database> get db async {
    final Database? existing = _db;
    if (existing != null) return existing;
    final Directory dir = await getApplicationDocumentsDirectory();
    final String path = p.join(dir.path, AppConfig.dbName);
    final Database opened = await openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE captures (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            image_path TEXT NOT NULL,
            source TEXT NOT NULL,
            location TEXT NOT NULL DEFAULT '',
            calibrated_path TEXT,
            white_r INTEGER,
            white_g INTEGER,
            white_b INTEGER,
            calibration_method TEXT NOT NULL DEFAULT 'none',
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE comparisons (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            reference_capture_id TEXT NOT NULL,
            target_capture_id TEXT NOT NULL,
            processed_path TEXT NOT NULL,
            delta_e REAL NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX ix_captures_session ON captures(session_id)');
        await db.execute(
            'CREATE INDEX ix_comparisons_session ON comparisons(session_id)');
      },
    );
    _db = opened;
    return opened;
  }

  Future<List<CompareSession>> listSessions() async {
    final Database d = await db;
    final List<Map<String, Object?>> rows = await d.query(
      'sessions',
      orderBy: 'created_at DESC',
    );
    return rows.map(_sessionFrom).toList();
  }

  Future<CompareSession?> getSession(String id) async {
    final Database d = await db;
    final List<Map<String, Object?>> rows =
        await d.query('sessions', where: 'id = ?', whereArgs: <Object>[id]);
    return rows.isEmpty ? null : _sessionFrom(rows.first);
  }

  Future<void> insertSession(CompareSession session) async {
    final Database d = await db;
    await d.insert('sessions', <String, Object?>{
      'id': session.id,
      'name': session.name,
      'note': session.note,
      'created_at': session.createdAt.millisecondsSinceEpoch,
    });
  }

  Future<void> updateSession(CompareSession session) async {
    final Database d = await db;
    await d.update(
      'sessions',
      <String, Object?>{'name': session.name, 'note': session.note},
      where: 'id = ?',
      whereArgs: <Object>[session.id],
    );
  }

  Future<void> deleteSession(String id) async {
    final Database d = await db;
    await d.delete('captures', where: 'session_id = ?', whereArgs: <Object>[id]);
    await d.delete('comparisons',
        where: 'session_id = ?', whereArgs: <Object>[id]);
    await d.delete('sessions', where: 'id = ?', whereArgs: <Object>[id]);
  }

  Future<List<Capture>> capturesOf(String sessionId) async {
    final Database d = await db;
    final List<Map<String, Object?>> rows = await d.query(
      'captures',
      where: 'session_id = ?',
      whereArgs: <Object>[sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_captureFrom).toList();
  }

  Future<void> insertCapture(Capture capture) async {
    final Database d = await db;
    await d.insert('captures', <String, Object?>{
      'id': capture.id,
      'session_id': capture.sessionId,
      'role': capture.role,
      'image_path': capture.imagePath,
      'source': capture.source,
      'location': capture.location,
      'calibrated_path': capture.calibratedPath,
      'white_r': capture.whiteR,
      'white_g': capture.whiteG,
      'white_b': capture.whiteB,
      'calibration_method': capture.calibrationMethod,
      'created_at': capture.createdAt.millisecondsSinceEpoch,
    });
  }

  Future<void> updateCaptureWhite(Capture capture) async {
    final Database d = await db;
    await d.update(
      'captures',
      <String, Object?>{
        'calibrated_path': capture.calibratedPath,
        'white_r': capture.whiteR,
        'white_g': capture.whiteG,
        'white_b': capture.whiteB,
        'calibration_method': capture.calibrationMethod,
      },
      where: 'id = ?',
      whereArgs: <Object>[capture.id],
    );
  }

  /// 删除一张采集，连同它的对比结果。
  Future<void> deleteCapture(String captureId, String sessionId) async {
    final Database d = await db;
    await d.delete(
      'comparisons',
      where: 'session_id = ? AND target_capture_id = ?',
      whereArgs: <Object>[sessionId, captureId],
    );
    await d.delete('captures', where: 'id = ?', whereArgs: <Object>[captureId]);
  }

  Future<Map<String, Comparison>> comparisonsOf(String sessionId) async {
    final Database d = await db;
    final List<Map<String, Object?>> rows = await d.query(
      'comparisons',
      where: 'session_id = ?',
      whereArgs: <Object>[sessionId],
    );
    return <String, Comparison>{
      for (final Map<String, Object?> row in rows)
        '${row['target_capture_id']}': _comparisonFrom(row),
    };
  }

  Future<void> upsertComparison(Comparison comparison) async {
    final Database d = await db;
    await d.delete(
      'comparisons',
      where: 'session_id = ? AND target_capture_id = ?',
      whereArgs: <Object>[comparison.sessionId, comparison.targetCaptureId],
    );
    await d.insert('comparisons', <String, Object?>{
      'id': comparison.id,
      'session_id': comparison.sessionId,
      'reference_capture_id': comparison.referenceCaptureId,
      'target_capture_id': comparison.targetCaptureId,
      'processed_path': comparison.processedPath,
      'delta_e': comparison.deltaE,
      'note': comparison.note,
      'created_at': comparison.createdAt.millisecondsSinceEpoch,
    });
  }

  Future<SessionDetail?> detail(String sessionId) async {
    final CompareSession? session = await getSession(sessionId);
    if (session == null) return null;
    final List<Capture> captures = await capturesOf(sessionId);
    Capture? reference;
    final List<Capture> targets = <Capture>[];
    for (final Capture c in captures) {
      if (c.isReference) {
        reference ??= c;
      } else {
        targets.add(c);
      }
    }
    return SessionDetail(
      session: session,
      reference: reference,
      targets: targets,
      comparisons: await comparisonsOf(sessionId),
    );
  }

  CompareSession _sessionFrom(Map<String, Object?> row) {
    return CompareSession(
      id: '${row['id']}',
      name: '${row['name']}',
      note: '${row['note'] ?? ''}',
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((row['created_at'] as num).toInt()),
    );
  }

  Capture _captureFrom(Map<String, Object?> row) {
    return Capture(
      id: '${row['id']}',
      sessionId: '${row['session_id']}',
      role: '${row['role']}',
      imagePath: '${row['image_path']}',
      source: '${row['source']}',
      location: '${row['location'] ?? ''}',
      calibratedPath: row['calibrated_path'] as String?,
      whiteR: (row['white_r'] as num?)?.toInt(),
      whiteG: (row['white_g'] as num?)?.toInt(),
      whiteB: (row['white_b'] as num?)?.toInt(),
      calibrationMethod: '${row['calibration_method'] ?? 'none'}',
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((row['created_at'] as num).toInt()),
    );
  }

  Comparison _comparisonFrom(Map<String, Object?> row) {
    return Comparison(
      id: '${row['id']}',
      sessionId: '${row['session_id']}',
      referenceCaptureId: '${row['reference_capture_id']}',
      targetCaptureId: '${row['target_capture_id']}',
      processedPath: '${row['processed_path']}',
      deltaE: (row['delta_e'] as num).toDouble(),
      note: '${row['note'] ?? ''}',
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((row['created_at'] as num).toInt()),
    );
  }
}
