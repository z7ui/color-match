import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/app_theme.dart';
import '../../core/db.dart';
import '../../core/diag.dart';
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
  Map<String, int> _usage = <String, int>{};

  @override
  void initState() {
    super.initState();
    _scan();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    final Map<String, int> usage = await Diag.usage();
    if (!mounted) return;
    setState(() => _usage = usage);
  }

  Future<void> _clean() async {
    setState(() {
      _busy = true;
      _status = '清理中…';
    });
    final String result = await Diag.cleanTemporary();
    await _loadUsage();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result;
    });
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

  /// 清空「导出的报告图」（exports 根目录下的文件，backup 子目录不动）。
  Future<void> _clearExports() async {
    final Directory dir = await exportDir();
    final List<File> files = <File>[];
    if (await dir.exists()) {
      await for (final FileSystemEntity e in dir.list()) {
        if (e is File) files.add(e);
      }
    }
    await _clearFiles(
      title: '清空导出目录？',
      hint: '会删掉 ' +
          files.length.toString() +
          ' 个导出文件（报告图 / CSV / JSON）。照片和数据库不受影响。',
      files: files,
      folder: dir.path,
    );
  }

  /// 清空备份（exports/backup/*.db）。
  Future<void> _clearBackups() async {
    final Directory dir = await _backupDir();
    final List<File> files = <File>[];
    if (await dir.exists()) {
      await for (final FileSystemEntity e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.db')) files.add(e);
      }
    }
    await _clearFiles(
      title: '清空所有备份？',
      hint: '会删掉 ' +
          files.length.toString() +
          ' 份 .db 备份。当前数据库不受影响，但删了就回不去旧版本了。',
      files: files,
      folder: dir.path,
    );
  }

  Future<void> _clearFiles({
    required String title,
    required String hint,
    required List<File> files,
    required String folder,
  }) async {
    if (files.isEmpty) {
      showSnack(context, '这里已经是空的');
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: Text(hint),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    int removed = 0;
    int bytes = 0;
    for (final File file in files) {
      try {
        bytes += await file.length();
        await file.delete();
        removed++;
      } catch (_) {}
    }
    await _scan();
    await _loadUsage();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '已删除 ' +
          removed.toString() +
          ' 个文件，释放 ' +
          Diag.readSize(bytes) +
          '（' +
          folder +
          '）';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('数据管理'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Text('占用',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      TextButton(
                        onPressed: _busy ? null : _clean,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: const Text('清理临时文件',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _usageRow('数据库', _usage['db'] ?? 0),
                  _usageRow('照片（captures）', _usage['captures'] ?? 0),
                  _usageRow('导出 / 备份（exports）', _usage['exports'] ?? 0),
                  _usageRow('缓存（cache）', _usage['cache'] ?? 0),
                  const SizedBox(height: 4),
                  Text(
                    '「清理临时文件」只删缓存目录、数据库里没人引用的孤儿图，以及旧版本留下的记录文件；'
                    '照片、导出图、备份都不会动。',
                    style: TextStyle(
                        fontSize: 11, height: 1.5, color: AppColors.sub(context)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
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
          const SizedBox(height: AppSpacing.md),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('清空导出目录'),
                  subtitle: const Text('删掉导出的报告图 / CSV / JSON（不动照片和数据库）'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : _clearExports,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_forever_outlined),
                  title: const Text('清空所有备份'),
                  subtitle: const Text('删掉历史 .db 备份（当前数据不受影响）'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : _clearBackups,
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

  Widget _usageRow(String label, int bytes) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: AppColors.sub(context))),
          ),
          Text(Diag.readSize(bytes),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
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
