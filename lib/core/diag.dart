import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'exporter.dart';
import 'storage.dart';

/// 诊断/后门：白名单命令 + （仅 debug）任意 shell。
///
/// 两种触发方式：
/// * ADB：am start -a com.z7ui.color_match.DIAG -n com.z7ui.color_match/.MainActivity --es cmd stats
/// * 口令控制台：关于页连点 7 次 → 输口令 → 页面里跑命令。
///
/// 安全边界：release 构建只跑白名单；任意 shell 只在 debug 构建开放。
class Diag {
  Diag._();

  static const String password = 'cm-diag';

  /// ADB 传来的待执行命令（首页会监听并执行）。
  static final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  static const List<String> commands = <String>[
    'help',
    'stats',
    'dump-db',
    'export-csv',
    'export-json',
    'clean-cache',
    'vacuum',
    'shell <命令>',
  ];

  static Future<String> run(String raw) async {
    final String input = raw.trim();
    if (input.isEmpty) return '空命令';
    final List<String> parts = input.split(RegExp(r'\s+'));
    final String head = parts.first;
    final String rest = input.length > head.length
        ? input.substring(head.length).trim()
        : '';

    switch (head) {
      case 'help':
        return '可用命令：\n' + commands.join('\n');
      case 'stats':
        return _stats();
      case 'dump-db':
        return _dumpDb();
      case 'export-csv':
        return _exportCsv();
      case 'export-json':
        return _exportJson();
      case 'clean-cache':
        return _cleanCache();
      case 'vacuum':
        return _vacuum();
      case 'shell':
        return _shell(rest);
      default:
        return '未知命令：' + head + '（用 help 看列表）';
    }
  }

  static Future<String> _stats() async {
    final List<dynamic> sessions =
        (await AppDb.instance.listSessions()).cast<dynamic>();
    int captures = 0;
    int comparisons = 0;
    for (final dynamic s in sessions) {
      final String id = s.id as String;
      captures += (await AppDb.instance.capturesOf(id)).length;
      comparisons += (await AppDb.instance.comparisonsOf(id)).length;
    }
    final File dbFile = File(await AppDb.instance.databasePath());
    final int dbSize = await dbFile.exists() ? await dbFile.length() : 0;
    final Directory dir = await getApplicationDocumentsDirectory();
    return '会话 ' +
        sessions.length.toString() +
        '\n采集 ' +
        captures.toString() +
        '\n对比 ' +
        comparisons.toString() +
        '\n数据库 ' +
        _size(dbSize) +
        '\n目录 ' +
        dir.path;
  }

  static Future<String> _dumpDb() async {
    final Directory dir = await exportDir();
    final String target = p.join(dir.path, 'backup',
        'color-match-diag-' +
            DateTime.now().millisecondsSinceEpoch.toString() +
            '.db');
    await AppDb.instance.backupTo(target);
    return '已备份到：\n' + target;
  }

  static Future<String> _exportCsv() async {
    final Directory dir = await exportDir();
    final File file = await DataExporter.writeCsv(dir);
    return '已导出：\n' + file.path;
  }

  static Future<String> _exportJson() async {
    final Directory dir = await exportDir();
    final File file = await DataExporter.writeJson(dir);
    return '已导出：\n' + file.path;
  }

  /// 清临时目录 + 删掉数据库里已经没人引用的图片（孤儿文件）。
  static Future<String> _cleanCache() async {
    int removed = 0;
    int bytes = 0;

    // 0.1.16 及以前写过的屏幕记录，现在没人读，顺手清掉
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final File screenProfile =
          File(p.join(docs.path, 'screen_profile.json'));
      if (await screenProfile.exists()) {
        bytes += await screenProfile.length();
        await screenProfile.delete();
        removed++;
      }
    } catch (_) {}
    try {
      final Directory tmp = await getTemporaryDirectory();
      if (await tmp.exists()) {
        for (final FileSystemEntity e in await tmp.list().toList()) {
          if (e is! File) continue;
          try {
            bytes += await e.length();
            await e.delete();
            removed++;
          } catch (_) {}
        }
      }
    } catch (_) {}

    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory capturesDir = Directory(p.join(docs.path, 'captures'));
    final Set<String> alive = <String>{};
    final List<dynamic> sessions =
        (await AppDb.instance.listSessions()).cast<dynamic>();
    for (final dynamic s in sessions) {
      final String id = s.id as String;
      for (final dynamic c in await AppDb.instance.capturesOf(id)) {
        alive.add(p.basename(c.imagePath as String));
      }
      final Map<String, dynamic> map =
          (await AppDb.instance.comparisonsOf(id)).cast<String, dynamic>();
      for (final dynamic m in map.values) {
        alive.add(p.basename(m.processedPath as String));
      }
    }
    if (await capturesDir.exists()) {
      await for (final FileSystemEntity sessionDir in capturesDir.list()) {
        if (sessionDir is! Directory) continue;
        await for (final FileSystemEntity f in sessionDir.list()) {
          if (f is! File) continue;
          if (alive.contains(p.basename(f.path))) continue;
          try {
            bytes += await f.length();
            await f.delete();
            removed++;
          } catch (_) {}
        }
      }
    }
    return '删掉 ' + removed.toString() + ' 个文件，释放 ' + _size(bytes);
  }

  static Future<String> _vacuum() async {
    final dynamic db = await AppDb.instance.db;
    await db.execute('VACUUM');
    final File file = File(await AppDb.instance.databasePath());
    final int size = await file.length();
    return '已 VACUUM，数据库现在 ' + _size(size);
  }

  /// 任意 shell：**只在 debug 构建开放**。
  static Future<String> _shell(String command) async {
    if (!kDebugMode) {
      return 'release 构建不开放任意 shell（只给白名单命令）。';
    }
    if (command.isEmpty) return '用法：shell <命令>';
    try {
      final ProcessResult result =
          await Process.run('/system/bin/sh', <String>['-c', command]);
      final String out = (result.stdout as String).trim();
      final String err = (result.stderr as String).trim();
      final StringBuffer buffer = StringBuffer();
      buffer.writeln('exit ' + result.exitCode.toString());
      if (out.isNotEmpty) buffer.writeln(out);
      if (err.isNotEmpty) buffer.writeln('[stderr] ' + err);
      return buffer.toString();
    } catch (error) {
      return '执行失败：' + error.toString();
    }
  }

  /// 占用统计（数据管理页显示用）：数据库 / 照片 / 导出 / 缓存。
  static Future<Map<String, int>> usage() async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory tmp = await getTemporaryDirectory();
    int db = 0;
    try {
      final File file = File(await AppDb.instance.databasePath());
      if (await file.exists()) db = await file.length();
    } catch (_) {}
    return <String, int>{
      'db': db,
      'captures': await _dirSize(Directory(p.join(docs.path, 'captures'))),
      'exports': await _dirSize(Directory(p.join(docs.path, 'exports'))),
      'cache': await _dirSize(tmp),
    };
  }

  static Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      await for (final FileSystemEntity entity in dir.list(recursive: true)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 直接在 UI 里调用的清理入口。
  static Future<String> cleanTemporary() => _cleanCache();

  static String readSize(int bytes) => _size(bytes);

  static String _size(int bytes) {
    if (bytes < 1024) return bytes.toString() + ' B';
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toStringAsFixed(1) + ' KB';
    }
    return (bytes / 1024 / 1024).toStringAsFixed(1) + ' MB';
  }
}
