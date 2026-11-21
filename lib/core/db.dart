import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'config.dart';
import 'models.dart';

/// 本地 SQLite：会话、采集、对比结果。
///
/// 四条硬约束：
/// 1. **打开只做一次**（缓存 Future，否则两个页面同时首次访问会 open 两次）；
/// 2. **多表改动走事务**，避免崩一半留下孤儿行；
/// 3. 删参照要连带删掉以它为基础的对比结果，并**把成图文件路径回传给调用方去删**
///    （以前只删 DB 行，磁盘上留一堆 _matched.jpg）；
/// 4. 备份/恢复要先关库再拷文件，不能对着正在写的库 copy。
class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  static const int schemaVersion = 4;

  Database? _db;
  Future<Database>? _opening;
  String? _path;

  Future<Database> get db {
    final Database? existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    return _opening ??= _open();
  }

  /// 数据库文件路径（备份/导出用）。
  Future<String> databasePath() async {
    final String? cached = _path;
    if (cached != null) return cached;
    final Directory dir = await getApplicationDocumentsDirectory();
    _path = p.join(dir.path, AppConfig.dbName);
    return _path!;
  }

  Future<Database> _open() async {
    final String path = await databasePath();
    final Database opened = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (Database db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (Database db, int version) async {
        await _createSchema(db);
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await _addColumnIfMissing(
              db, 'comparisons', 'delta_e_before', 'REAL NOT NULL DEFAULT 0');
        }
        if (oldVersion < 3) {
          await _addColumnIfMissing(db, 'captures', 'check_r', 'INTEGER');
          await _addColumnIfMissing(db, 'captures', 'check_g', 'INTEGER');
          await _addColumnIfMissing(db, 'captures', 'check_b', 'INTEGER');
          await _addColumnIfMissing(
              db, 'comparisons', 'error_floor', 'REAL NOT NULL DEFAULT 0');
        }
        if (oldVersion < 4) {
          await _addColumnIfMissing(
              db, 'captures', 'used_torch', 'INTEGER NOT NULL DEFAULT 0');
        }
      },
    );
    _db = opened;
    return opened;
  }

  Future<void> _addColumnIfMissing(
      Database db, String table, String column, String type) async {
    final List<Map<String, Object?>> cols =
        await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((Map<String, Object?> c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  Future<void> _createSchema(Database db) async {
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
        white_r INTEGER,
        white_g INTEGER,
        white_b INTEGER,
        calibration_method TEXT NOT NULL DEFAULT 'none',
        check_r INTEGER,
        check_g INTEGER,
        check_b INTEGER,
        used_torch INTEGER NOT NULL DEFAULT 0,
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
        delta_e_before REAL NOT NULL DEFAULT 0,
        error_floor REAL NOT NULL DEFAULT 0,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX ix_captures_session ON captures(session_id)');
    await db.execute(
        'CREATE INDEX ix_comparisons_session ON comparisons(session_id)');
    await db.execute(
        'CREATE INDEX ix_comparisons_reference ON comparisons(reference_capture_id)');
  }

  /// 关库（备份/恢复/清缓存前必须调，之后重新 open）。
  Future<void> close() async {
    final Database? existing = _db;
    _db = null;
    _opening = null;
    if (existing != null) {
      try {
        await existing.close();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- sessions

  Future<List<CompareSession>> listSessions() async {
    final Database d = await db;
    final List<Map<String, Object?>> rows =
        await d.query('sessions', orderBy: 'created_at DESC');
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

  /// 删除会话，返回被删掉的成图路径（交给调用方删文件）。
  Future<List<String>> deleteSession(String id) async {
    final Database d = await db;
    final List<String> files = await processedPathsOf(id);
    await d.transaction((Transaction txn) async {
      await txn.delete('comparisons',
          where: 'session_id = ?', whereArgs: <Object>[id]);
      await txn.delete('captures',
          where: 'session_id = ?', whereArgs: <Object>[id]);
      await txn.delete('sessions', where: 'id = ?', whereArgs: <Object>[id]);
    });
    return files;
  }

  /// 每个会话的采集数 / 对比数（列表页判断"空项目"用，一条 SQL 搞定）。
  Future<Map<String, SessionStat>> stats() async {
    final Database d = await db;
    final Map<String, int> captures = <String, int>{};
    final Map<String, int> comparisons = <String, int>{};
    for (final Map<String, Object?> row in await d.rawQuery(
        'SELECT session_id, COUNT(*) AS n FROM captures GROUP BY session_id')) {
      captures['${row['session_id']}'] = (row['n'] as num).toInt();
    }
    for (final Map<String, Object?> row in await d.rawQuery(
        'SELECT session_id, COUNT(*) AS n FROM comparisons GROUP BY session_id')) {
      comparisons['${row['session_id']}'] = (row['n'] as num).toInt();
    }
    final Set<String> keys = <String>{...captures.keys, ...comparisons.keys};
    return <String, SessionStat>{
      for (final String key in keys)
        key: SessionStat(
          captures: captures[key] ?? 0,
          comparisons: comparisons[key] ?? 0,
        ),
    };
  }

  // ---------------------------------------------------------------- captures

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
      'white_r': capture.whiteR,
      'white_g': capture.whiteG,
      'white_b': capture.whiteB,
      'calibration_method': capture.calibrationMethod,
      'check_r': capture.checkR,
      'check_g': capture.checkG,
      'check_b': capture.checkB,
      'used_torch': capture.usedTorch ? 1 : 0,
      'created_at': capture.createdAt.millisecondsSinceEpoch,
    });
  }

  /// 只更新标定相关的列（标定 = 记白点，不改照片）。
  Future<void> updateCaptureCalibration(
    String captureId, {
    required int whiteR,
    required int whiteG,
    required int whiteB,
    int? checkR,
    int? checkG,
    int? checkB,
    String method = 'white_patch',
  }) async {
    final Database d = await db;
    await d.update(
      'captures',
      <String, Object?>{
        'white_r': whiteR,
        'white_g': whiteG,
        'white_b': whiteB,
        'check_r': checkR,
        'check_g': checkG,
        'check_b': checkB,
        'calibration_method': method,
      },
      where: 'id = ?',
      whereArgs: <Object>[captureId],
    );
  }

  /// 记录「在哪拍的 / 什么光」——多光源复检靠它区分。
  Future<void> updateCaptureLocation(String captureId, String location) async {
    final Database d = await db;
    await d.update(
      'captures',
      <String, Object?>{'location': location},
      where: 'id = ?',
      whereArgs: <Object>[captureId],
    );
  }

  /// 删除一张采集，返回被删掉的成图路径（交给调用方删文件）。
  Future<List<String>> deleteCapture(String captureId, String sessionId) async {
    final Database d = await db;
    final List<String> files = <String>[];
    final List<Map<String, Object?>> rows = await d.query(
      'comparisons',
      columns: <String>['processed_path'],
      where: 'session_id = ? AND (target_capture_id = ? OR reference_capture_id = ?)',
      whereArgs: <Object>[sessionId, captureId, captureId],
    );
    for (final Map<String, Object?> row in rows) {
      final Object? path = row['processed_path'];
      if (path is String && path.isNotEmpty) files.add(path);
    }
    await d.transaction((Transaction txn) async {
      await txn.delete(
        'comparisons',
        where:
            'session_id = ? AND (target_capture_id = ? OR reference_capture_id = ?)',
        whereArgs: <Object>[sessionId, captureId, captureId],
      );
      await txn.delete('captures', where: 'id = ?', whereArgs: <Object>[captureId]);
    });
    return files;
  }

  // ------------------------------------------------------------- comparisons

  Future<List<String>> processedPathsOf(String sessionId) async {
    final Database d = await db;
    final List<Map<String, Object?>> rows = await d.query(
      'comparisons',
      columns: <String>['processed_path'],
      where: 'session_id = ?',
      whereArgs: <Object>[sessionId],
    );
    return <String>[
      for (final Map<String, Object?> row in rows)
        if (row['processed_path'] is String)
          row['processed_path']! as String,
    ];
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
    await d.transaction((Transaction txn) async {
      await txn.delete(
        'comparisons',
        where: 'session_id = ? AND target_capture_id = ?',
        whereArgs: <Object>[comparison.sessionId, comparison.targetCaptureId],
      );
      await txn.insert('comparisons', <String, Object?>{
        'id': comparison.id,
        'session_id': comparison.sessionId,
        'reference_capture_id': comparison.referenceCaptureId,
        'target_capture_id': comparison.targetCaptureId,
        'processed_path': comparison.processedPath,
        'delta_e': comparison.deltaE,
        'delta_e_before': comparison.deltaEBefore,
        'error_floor': comparison.errorFloor,
        'note': comparison.note,
        'created_at': comparison.createdAt.millisecondsSinceEpoch,
      });
    });
  }

  Future<void> deleteComparison(String sessionId, String targetCaptureId) async {
    final Database d = await db;
    await d.delete(
      'comparisons',
      where: 'session_id = ? AND target_capture_id = ?',
      whereArgs: <Object>[sessionId, targetCaptureId],
    );
  }

  /// 让整个 session 的对比结果失效，返回旧成图路径（调用方删文件）。
  Future<List<String>> invalidateComparisons(String sessionId) async {
    final Database d = await db;
    final List<String> files = await processedPathsOf(sessionId);
    await d.delete('comparisons',
        where: 'session_id = ?', whereArgs: <Object>[sessionId]);
    return files;
  }

  /// 让某一张目标图的对比结果失效，返回旧成图路径。
  Future<List<String>> invalidateComparisonOf(
      String sessionId, String targetCaptureId) async {
    final Database d = await db;
    final List<Map<String, Object?>> rows = await d.query(
      'comparisons',
      columns: <String>['processed_path'],
      where: 'session_id = ? AND target_capture_id = ?',
      whereArgs: <Object>[sessionId, targetCaptureId],
    );
    final List<String> files = <String>[
      for (final Map<String, Object?> row in rows)
        if (row['processed_path'] is String)
          row['processed_path']! as String,
    ];
    await d.delete(
      'comparisons',
      where: 'session_id = ? AND target_capture_id = ?',
      whereArgs: <Object>[sessionId, targetCaptureId],
    );
    return files;
  }

  // ------------------------------------------------------------------ detail

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

  /// 导出用：把所有会话/采集/对比摊平成行（CSV、JSON 都从它生成）。
  Future<List<Map<String, Object?>>> exportRows() async {
    final Database d = await db;
    final List<Map<String, Object?>> rows = await d.rawQuery('''
      SELECT s.id AS session_id, s.name AS session_name, s.note AS session_note,
             s.created_at AS session_created,
             c.id AS capture_id, c.role AS role, c.location AS location,
             c.image_path AS image_path, c.white_r, c.white_g, c.white_b,
             c.check_r, c.check_g, c.check_b, c.used_torch,
             c.calibration_method, c.created_at AS capture_created,
             m.delta_e, m.delta_e_before, m.error_floor, m.processed_path,
             m.created_at AS comparison_created
      FROM sessions s
      LEFT JOIN captures c ON c.session_id = s.id
      LEFT JOIN comparisons m ON m.session_id = s.id
      ORDER BY s.created_at DESC, c.created_at ASC
    ''');
    return rows;
  }

  /// 备份：先关库，再把文件复制出去，最后重新打开。
  Future<void> backupTo(String targetPath) async {
    final String source = await databasePath();
    await close();
    final File target = File(targetPath);
    await target.parent.create(recursive: true);
    await File(source).copy(targetPath);
    // 恢复可用状态
    await db;
  }

  /// 恢复：关库 -> 覆盖 -> 重新打开（并跑迁移）。
  Future<void> restoreFrom(String sourcePath) async {
    final String target = await databasePath();
    await close();
    await File(sourcePath).copy(target);
    await db;
  }

  // ------------------------------------------------------------- row mapping

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
      whiteR: (row['white_r'] as num?)?.toInt(),
      whiteG: (row['white_g'] as num?)?.toInt(),
      whiteB: (row['white_b'] as num?)?.toInt(),
      calibrationMethod: '${row['calibration_method'] ?? 'none'}',
      checkR: (row['check_r'] as num?)?.toInt(),
      checkG: (row['check_g'] as num?)?.toInt(),
      checkB: (row['check_b'] as num?)?.toInt(),
      usedTorch: ((row['used_torch'] as num?) ?? 0).toInt() == 1,
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
      deltaEBefore: ((row['delta_e_before'] as num?) ?? 0).toDouble(),
      errorFloor: ((row['error_floor'] as num?) ?? 0).toDouble(),
      note: '${row['note'] ?? ''}',
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((row['created_at'] as num).toInt()),
    );
  }
}
