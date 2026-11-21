import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/diag.dart';

/// 诊断控制台：输口令后可以跑白名单命令（release 下不开放任意 shell）。
class DiagPage extends StatefulWidget {
  const DiagPage({super.key});

  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _unlocked = false;
  bool _busy = false;
  String _output = '输入命令后点「执行」，或直接点下面的按钮。';

  @override
  void dispose() {
    _input.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(String command) async {
    setState(() {
      _busy = true;
      _output = '执行中…';
    });
    final String result = await Diag.run(command);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _output = '> ' + command + '\n\n' + result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('诊断'),
      body: !_unlocked ? _lockView() : _consoleView(),
    );
  }

  Widget _lockView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.lock_outline, size: 44, color: AppColors.textHint),
            const SizedBox(height: 12),
            const Text('输入口令',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(hintText: '口令'),
              onSubmitted: (_) => _unlock(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _unlock, child: const Text('进入')),
            ),
          ],
        ),
      ),
    );
  }

  void _unlock() {
    if (_password.text.trim() == Diag.password) {
      setState(() => _unlocked = true);
    } else {
      showSnack(context, '口令不对', error: true);
    }
  }

  Widget _consoleView() {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _input,
                decoration: const InputDecoration(
                  hintText: 'stats / dump-db / clean-cache / shell ls',
                ),
                onSubmitted: _run,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : () => _run(_input.text),
              child: const Text('执行'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          children: <Widget>[
            for (final String command in <String>[
              'stats',
              'dump-db',
              'export-csv',
              'export-json',
              'clean-cache',
              'vacuum',
              'help',
            ])
              ActionChip(
                label: Text(command, style: const TextStyle(fontSize: 12)),
                onPressed: _busy ? null : () => _run(command), // chip 需要带参数，保留闭包
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.card(context),
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.line(context)),
          ),
          child: SelectableText(
            _output,
            style: const TextStyle(
                fontSize: 12, height: 1.5, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'ADB 触发：\n'
              'adb shell am start -a com.z7ui.color_match.DIAG \\\n'
              '  -n com.z7ui.color_match/.MainActivity --es cmd stats\n\n'
              'release 构建只跑白名单；shell 命令只在 debug 构建可用。',
          style: TextStyle(
              fontSize: 11, height: 1.6, color: AppColors.sub(context)),
        ),
      ],
    );
  }
}
