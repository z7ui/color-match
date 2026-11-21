import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_theme.dart';
import '../../core/config.dart';
import '../../core/db.dart';
import '../../core/diag.dart';
import '../../core/models.dart';
import '../settings/about_page.dart';
import '../settings/guide_page.dart';
import 'session_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<CompareSession>> _future;
  Map<String, SessionStat> _stats = <String, SessionStat>{};

  @override
  void initState() {
    super.initState();
    _future = AppDb.instance.listSessions();
    _loadStats();
    Diag.pending.addListener(_onDiagCommand);
    // 冷启动时可能已经有命令在排队
    WidgetsBinding.instance.addPostFrameCallback((_) => _onDiagCommand());
  }

  @override
  void dispose() {
    Diag.pending.removeListener(_onDiagCommand);
    super.dispose();
  }

  /// ADB 触发的命令：跑完用对话框把结果摊开（不占 UI，也不依赖控制台页面）。
  Future<void> _onDiagCommand() async {
    final String? command = Diag.pending.value;
    if (command == null || command.isEmpty) return;
    Diag.pending.value = null;
    final String result = await Diag.run(command);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('诊断 · ' + command),
        content: SingleChildScrollView(
          child: SelectableText(
            result,
            style: const TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
        actions: <Widget>[
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  }

  void _reload() {
    setState(() => _future = AppDb.instance.listSessions());
    _loadStats();
  }

  /// 列表要显示「这个项目是不是空的」，所以顺带把每个会话的采集/对比数取回来。
  Future<void> _loadStats() async {
    try {
      final Map<String, SessionStat> stats = await AppDb.instance.stats();
      if (!mounted) return;
      setState(() => _stats = stats);
    } catch (_) {}
  }

  Future<void> _create() async {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final TextEditingController controller = TextEditingController(
        text: '对比 ${now.month}${now.day}-${two(now.hour)}${two(now.minute)}${two(now.second)}');
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('新建对比'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            hintText: '比如：客厅瓷砖 / 卫生间门',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;

    final Directory dir = await getApplicationDocumentsDirectory();
    final String id = const Uuid().v4();
    await AppDb.instance.insertSession(CompareSession(
      id: id,
      name: name,
      createdAt: DateTime.now(),
    ));
    await Directory(p.join(dir.path, 'captures', id)).create(recursive: true);
    if (!mounted) return;
    _reload();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(sessionId: id),
      ),
    );
    if (!mounted) return;
    _reload();
  }

  Future<void> _edit(CompareSession session) async {
    final TextEditingController nameController =
        TextEditingController(text: session.name);
    final TextEditingController noteController =
        TextEditingController(text: session.note);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('编辑'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '型号 / 门店 / 价格，随便记',
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    final String name = nameController.text.trim();
    final String note = noteController.text.trim();
    nameController.dispose();
    noteController.dispose();
    if (ok != true || name.isEmpty) return;
    await AppDb.instance
        .updateSession(session.copyWith(name: name, note: note));
    if (!mounted) return;
    _reload();
    showSnack(context, '已保存');
  }

  Future<void> _confirmDelete(CompareSession session) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除这个对比项目？'),
        content: Text('「${session.name}」里的所有照片和对比结果都会删掉，不能恢复。'),
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

    await AppDb.instance.deleteSession(session.id);
    final Directory dir = await getApplicationDocumentsDirectory();
    try {
      final Directory sessionDir =
          Directory(p.join(dir.path, 'captures', session.id));
      if (await sessionDir.exists()) {
        await sessionDir.delete(recursive: true);
      }
    } catch (_) {}
    if (!mounted) return;
    _reload();
    showSnack(context, '已删除');
  }

  /// 有内容的项目用实心图标；空项目用空心虚线感，不看名字也能一眼分辨。
  Widget _sessionIcon(SessionStat stat) {
    final bool empty = stat.isEmpty;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: empty
            ? Colors.transparent
            : AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: empty
            ? Border.all(color: AppColors.line(context), width: 1.5)
            : null,
      ),
      child: Icon(
        empty ? Icons.add_photo_alternate_outlined : Icons.compare,
        color: empty ? AppColors.textHint : AppColors.primary,
        size: empty ? 20 : 24,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(AppConfig.appName, actions: <Widget>[
        IconButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const GuidePage()),
          ),
          icon: const Icon(Icons.help_outline),
          tooltip: '怎么用',
        ),
        IconButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const AboutPage()),
          ),
          icon: const Icon(Icons.info_outline),
          tooltip: '关于',
        ),
      ]),
      body: FutureBuilder<List<CompareSession>>(
        future: _future,
        builder: (BuildContext context,
            AsyncSnapshot<List<CompareSession>> snapshot) {
          if (snapshot.hasError) {
            // 以前数据库出错就一直转圈，用户只能杀进程
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(Icons.error_outline,
                        size: 48, color: AppColors.danger),
                    const SizedBox(height: 12),
                    const Text('读取本地记录失败',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text('${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(onPressed: _reload, child: const Text('重试')),
                  ],
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final List<CompareSession> sessions = snapshot.data!;
          if (sessions.isEmpty) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(Icons.colorize, size: 56, color: AppColors.textHint),
                    SizedBox(height: 16),
                    Text('还没有对比记录',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    SizedBox(height: 8),
                    Text(
                      '准备一张白纸：主体（瓷砖 / 门窗 / 小样）放中间，白纸放左下角。\n'
                      '家里拍一张、厂里拍一张，软件会把两边的光拉平，再比颜色。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, height: 1.6, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _create,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建第一个对比'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: sessions.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (BuildContext context, int i) {
              final CompareSession s = sessions[i];
              return Card(
                child: InkWell(
                  onLongPress: () => _edit(s),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SessionPage(sessionId: s.id),
                      ),
                    );
                    if (!mounted) return;
                    _reload();
                  },
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      children: <Widget>[
                        _sessionIcon(
                          _stats[s.id] ?? const SessionStat(),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Flexible(
                                    child: Text(s.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600)),
                                  ),
                                  if ((_stats[s.id] ?? const SessionStat()).isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: AppColors.line(context),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text('空项目',
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: AppColors.sub(context))),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${s.createdAt.year}-${s.createdAt.month.toString().padLeft(2, '0')}-${s.createdAt.day.toString().padLeft(2, '0')}'
                                ' ${s.createdAt.hour.toString().padLeft(2, '0')}:${s.createdAt.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textSecondary),
                              ),
                              if (s.note.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 2),
                                Text(
                                  s.note,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: AppColors.textHint),
                                ),
                              ],
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '更多',
                          onSelected: (String value) {
                            if (value == 'edit') {
                              _edit(s);
                            } else if (value == 'delete') {
                              _confirmDelete(s);
                            }
                          },
                          itemBuilder: (BuildContext ctx) =>
                              const <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(
                                value: 'edit', child: Text('重命名 / 备注')),
                            PopupMenuItem<String>(
                                value: 'delete', child: Text('删除项目')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建对比'),
      ),
    );
  }
}
