import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'db.dart';
import 'models.dart';

/// 数据导出：整库 JSON / 扁平 CSV。
///
/// 存在意义：数据库在应用私有目录，换手机就全没了；导出一份就能自己留档、
/// 也能丢进 Excel 算。
class DataExporter {
  DataExporter._();

  /// 整库导出成 JSON（会话 → 采集 → 对比，带全部参数）。
  static Future<File> writeJson(Directory dir) async {
    final List<CompareSession> sessions = await AppDb.instance.listSessions();
    final List<Map<String, Object?>> payload = <Map<String, Object?>>[];
    for (final CompareSession s in sessions) {
      final SessionDetail? detail = await AppDb.instance.detail(s.id);
      if (detail == null) continue;
      payload.add(<String, Object?>{
        'session': <String, Object?>{
          'id': s.id,
          'name': s.name,
          'note': s.note,
          'created_at': s.createdAt.toIso8601String(),
        },
        'captures': <Map<String, Object?>>[
          for (final Capture c in <Capture>[
            if (detail.reference != null) detail.reference!,
            ...detail.targets,
          ])
            <String, Object?>{
              'id': c.id,
              'role': c.role,
              'source': c.source,
              'location': c.location,
              'image': p.basename(c.imagePath),
              'white': c.isCalibrated
                  ? <String, int>{
                      'r': c.whiteR!,
                      'g': c.whiteG!,
                      'b': c.whiteB!,
                    }
                  : null,
              'checker': c.hasChecker
                  ? <String, int>{
                      'r': c.checkR!,
                      'g': c.checkG!,
                      'b': c.checkB!,
                    }
                  : null,
              'used_torch': c.usedTorch,
              'created_at': c.createdAt.toIso8601String(),
            },
        ],
        'comparisons': <Map<String, Object?>>[
          for (final Comparison c in detail.comparisons.values)
            <String, Object?>{
              'reference_capture_id': c.referenceCaptureId,
              'target_capture_id': c.targetCaptureId,
              'delta_e': c.deltaE,
              'delta_e_before': c.deltaEBefore,
              'error_floor': c.errorFloor,
              'trustworthy': c.trustworthy,
              'processed': p.basename(c.processedPath),
              'created_at': c.createdAt.toIso8601String(),
            },
        ],
      });
    }

    final File file = File(p.join(dir.path, _stamp() + '_color-match.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'app': 'color-match',
        'exported_at': DateTime.now().toIso8601String(),
        'sessions': payload,
      },
    ));
    return file;
  }

  /// 扁平 CSV：一行 = 一条对比（没有对比的采集也会出现，字段留空）。
  static Future<File> writeCsv(Directory dir) async {
    final List<Map<String, Object?>> rows = await AppDb.instance.exportRows();
    const List<String> columns = <String>[
      'session_id',
      'session_name',
      'session_note',
      'capture_id',
      'role',
      'location',
      'image_path',
      'white_r',
      'white_g',
      'white_b',
      'check_r',
      'check_g',
      'check_b',
      'used_torch',
      'delta_e',
      'delta_e_before',
      'error_floor',
      'processed_path',
      'comparison_created',
    ];
    final StringBuffer buffer = StringBuffer();
    buffer.writeln(columns.join(','));
    for (final Map<String, Object?> row in rows) {
      buffer.writeln(columns
          .map((String key) => _cell(row[key]))
          .join(','));
    }
    final File file = File(p.join(dir.path, _stamp() + '_color-match.csv'));
    // 带 BOM，Excel 打开中文不乱码
    await file.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(buffer.toString())]);
    return file;
  }

  static String _cell(Object? value) {
    if (value == null) return '';
    final String text = value.toString();
    if (text.contains(',') || text.contains('"') || text.contains('\n')) {
      return '"' + text.replaceAll('"', '""') + '"';
    }
    return text;
  }

  static String _stamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return now.year.toString() +
        two(now.month) +
        two(now.day) +
        '-' +
        two(now.hour) +
        two(now.minute) +
        two(now.second);
  }
}
