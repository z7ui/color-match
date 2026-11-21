import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_theme.dart';

/// 屏幕校色：没有仪器，只能做「人眼自检 + 记录」。
///
/// 四张测试卡：
/// 1. 暗部：5 块近黑灰，能分清几块 ≈ 屏幕黑位/对比度；
/// 2. 高光：5 块近白灰，全都糊成一片说明亮度太高；
/// 3. 白点：纯白 vs 245 白，应该能看出差别；
/// 4. 三原色：红绿蓝，判断有没有开护眼/夜间模式把颜色整个推掉。
///
/// 结论只能「记录」：告诉用户该怎么调，并把你调好的状态存下来，
/// 以后截图/对比出问题时能回头看。
class ScreenCalibrationPage extends StatefulWidget {
  const ScreenCalibrationPage({super.key});

  @override
  State<ScreenCalibrationPage> createState() => _ScreenCalibrationPageState();
}

class _ScreenCalibrationPageState extends State<ScreenCalibrationPage> {
  int _card = 0;
  String? _savedAt;

  static const String _fileName = 'screen_profile.json';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<File> _file() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  Future<void> _load() async {
    try {
      final File f = await _file();
      if (!await f.exists()) return;
      final Object? json = jsonDecode(await f.readAsString());
      if (json is Map && mounted) {
        setState(() => _savedAt = json['checked_at'] as String?);
      }
    } catch (_) {}
  }

  Future<void> _record() async {
    final File f = await _file();
    final String now = DateTime.now().toIso8601String();
    await f.writeAsString(jsonEncode(<String, Object?>{
      'checked_at': now,
      'card': _card,
    }));
    if (!mounted) return;
    setState(() => _savedAt = now);
    showSnack(context, '已记录：屏幕状态确认过了');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('屏幕校色'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          const Text(
            '这台手机没有测量仪器，只能做「人眼自检」。'
            '按下面的顺序把屏幕调到一个固定状态，然后记一笔。',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          SegmentedButton<int>(
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, label: Text('暗部')),
              ButtonSegment<int>(value: 1, label: Text('高光')),
              ButtonSegment<int>(value: 2, label: Text('白点')),
              ButtonSegment<int>(value: 3, label: Text('三原色')),
            ],
            selected: <int>{_card},
            onSelectionChanged: (Set<int> v) => setState(() => _card = v.first),
          ),
          const SizedBox(height: AppSpacing.md),
          AspectRatio(aspectRatio: 1.4, child: _cardView()),
          const SizedBox(height: AppSpacing.md),
          Text(_tip(),
              style: const TextStyle(
                  fontSize: 13, height: 1.6, color: AppColors.text)),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _record,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('屏幕已经调好，记录一下'),
            ),
          ),
          if (_savedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text('上次确认：' + _savedAt!,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.sub(context))),
            ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '为什么重要：走廊里看照片、在太阳下看照片，屏幕亮度不同，'
            '你判断「这两个颜色像不像」的结论也会变。把屏幕调到一个固定档位再看，结论才可比。',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: AppColors.sub(context)),
          ),
        ],
      ),
    );
  }

  Widget _cardView() {
    switch (_card) {
      case 0:
        return _strip(<int>[0, 4, 8, 12, 16], const Color(0xFF000000),
            const Color(0xFFFFFFFF));
      case 1:
        return _strip(<int>[255, 251, 247, 243, 239], const Color(0xFFFFFFFF),
            const Color(0xFF000000));
      case 2:
        return Row(
          children: <Widget>[
            Expanded(child: Container(color: const Color(0xFFFFFFFF))),
            Expanded(child: Container(color: const Color(0xFFF5F5F5))),
          ],
        );
      default:
        return Row(
          children: const <Widget>[
            Expanded(child: ColoredBox(color: Color(0xFFD62828))),
            Expanded(child: ColoredBox(color: Color(0xFF2A9D3F))),
            Expanded(child: ColoredBox(color: Color(0xFF1D4ED8))),
          ],
        );
    }
  }

  Widget _strip(List<int> values, Color background, Color foreground) {
    return Row(
      children: <Widget>[
        for (final int v in values)
          Expanded(
            child: ColoredBox(
              color: background,
              child: Center(
                child: Container(
                  width: 56,
                  height: 56,
                  color: Color.fromARGB(255, v, v, v),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _tip() {
    switch (_card) {
      case 0:
        return '暗部：5 块灰从深到浅。把屏幕亮度调到「能看清最左两块、但左一整块不发光」比较合适。'
            '如果 5 块糊成一片，说明你的屏幕对比度低或亮度太低，判色会偏「黑」。';
      case 1:
        return '高光：5 块近白灰。如果右边 2-3 块分不出来，说明亮度太高、高光被压平了——'
            '看白色瓷砖时容易把「米白」看成「纯白」。往下调一档亮度再试。';
      case 2:
        return '白点：左边纯白，右边 245 的近白。能看出差别说明高光余量还在；'
            '完全一样说明屏幕在高光处已经截断。';
      default:
        return '三原色：看红/绿/蓝是否「干净」。如果发青、发黄、发灰，'
            '多半是开了护眼模式/夜间模式/色弱模式——调色前一定先关掉。';
    }
  }
}
