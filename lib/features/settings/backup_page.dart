import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/app_theme.dart';
import '../../core/db.dart';
import '../../core/exporter.dart';
import '../../core/storage.dart';

/// 数据管理：备份数据库、恢复、导出 CSV / JSON。
///
/// 数据库在应用私有目录里，卸载或换机就没了，所以这里必须能手备份。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;
  String? _status;
  List<File> _backups = <File>[];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<Directory> _backupDir() async {
    final Directory dir = await exportDir();
    final Directory backup = Directory(p.join(dir.path, 'backup'));
    if (!await backup.exists()) await backup.create(recursive: true);
    return backup;
  }

  Future<void> _scan() async {
    try {
      final Directory dir = await _backupDir();
      final List<File> files = await dir
          .list()
          .where((FileSystemEntity e) =>
              e is File && e.path.toLowerCase().endsWith('.db'))
          .cast<File>()
          .toList();
      files.sort((File a, File b) => b.path.compareTo(a.path));
      if (!mounted) return;
      setState(() => _backups = files);
    } catch (_) {
      if (!mounted) return;
      setState(() => _backups = <File>[]);
    }
  }

  Future<void> _backup() async {
    setState(() {
      _busy = true;
      _status = '备份中…';
    });
    try {
      final Directory dir = await _backupDir();
      final DateTime now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final String name = 'color-match-' +
          now.year.toString() +
          two(now.month) +
          two(now.day) +
          '-' +
          two(now.hour) +
          two(now.minute) +
          two(now.second) +
          '.db';
      final String target = p.join(dir.path, name);
      await AppDb.instance.backupTo(target);
      await _scan();
      if (!mounted) return;
      setState(() => _status = '已备份：' + name);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '备份失败：' + error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(File file) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('用这份备份覆盖当前数据？'),
        content: Text(p.basename(file.path) +
            '\n\n当前所有会话、照片记录都会被替换（照片文件本身不会删）。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _status = '恢复中…';
    });
    try {
      await AppDb.instance.restoreFrom(file.path);
      if (!mounted) return;
      setState(() => _status = '已恢复：' + p.basename(file.path));
      showSnack(context, '恢复完成，返回首页查看');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '恢复失败：' + error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(bool json) async {
    setState(() {
      _busy = true;
      _status = json ? '导出 JSON…' : '导出 CSV…';
    });
    try {
      final Directory dir = await exportDir();
      final File file =
          json ? await DataExporter.writeJson(dir) : await DataExporter.writeCsv(dir);
      if (!mounted) return;
      setState(() => _status = '已导出：' + p.basename(file.path));
      await SharePlus.instance
          .share(ShareParams(files: <XFile>[XFile(file.path)]));
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '导出失败：' + error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('数据管理'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('备份数据库'),
                  subtitle: const Text('生成一份 .db 快照，放在导出目录（可分享）'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : _backup,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.table_chart_outlined),
                  title: const Text('导出 CSV'),
                  subtitle: const Text('一行一条对比，Excel 直接打开'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _export(false),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.data_object),
                  title: const Text('导出 JSON'),
                  subtitle: const Text('带会话 / 采集 / 对比三层结构，适合留档'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _export(true),
                ),
              ],
            ),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(_status!,
                  style: TextStyle(
                      fontSize: 12, color: AppColors.sub(context))),
            ),
          const SizedBox(height: AppSpacing.lg),
          Text('从备份恢复',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (_backups.isEmpty)
            Text('还没有备份文件。先点上面的「备份数据库」。',
                style: TextStyle(
                    fontSize: 12, color: AppColors.sub(context)))
          else
            ..._backups.map((File file) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(p.basename(file.path),
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(_sizeText(file),
                        style: const TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.restore),
                    onTap: _busy ? null : () => _restore(file),
                  ),
                )),
          const SizedBox(height: AppSpacing.lg),
          Text('照片本身不会被打包：备份只含数据库记录，照片仍在应用目录里。',
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: AppColors.sub(context))),
        ],
      ),
    );
  }

  String _sizeText(File file) {
    try {
      final int bytes = file.lengthSync();
      if (bytes < 1024) return bytes.toString() + ' B';
      if (bytes < 1024 * 1024) {
        return (bytes / 1024).toStringAsFixed(1) + ' KB';
      }
      return (bytes / 1024 / 1024).toStringAsFixed(1) + ' MB';
    } catch (_) {
      return '';
    }
  }
}
