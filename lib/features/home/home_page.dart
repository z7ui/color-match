import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_theme.dart';
import '../../core/db.dart';
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

  @override
  void initState() {
    super.initState();
    _future = AppDb.instance.listSessions();
  }

  void _reload() {
    setState(() => _future = AppDb.instance.listSessions());
  }

  Future<void> _create() async {
    final TextEditingController controller =
        TextEditingController(text: '瓷砖对比 ${DateTime.now().month}-${DateTime.now().day}');
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
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, AppConfigTitle.title, actions: <Widget>[
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
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final List<CompareSession> sessions = snapshot.data!;
          if (sessions.isEmpty) {
            return const Center(
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
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: sessions.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (BuildContext context, int i) {
              final CompareSession s = sessions[i];
              return Card(
                child: InkWell(
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SessionPage(sessionId: s.id),
                      ),
                    );
                    _reload();
                  },
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.compare, color: AppColors.primary),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(s.name,
                                  style: const TextStyle(
                                      fontSize: 15, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                '${s.createdAt.year}-${s.createdAt.month.toString().padLeft(2, '0')}-${s.createdAt.day.toString().padLeft(2, '0')}'
                                ' ${s.createdAt.hour.toString().padLeft(2, '0')}:${s.createdAt.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: AppColors.textHint),
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

class AppConfigTitle {
  static const String title = '选色助手';
}
