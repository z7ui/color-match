import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_theme.dart';
import '../../core/screen_control.dart';

/// 屏幕校色：没有仪器，只能做「人眼自检 + 记录」。
///
/// 四张测试卡：
/// 1. 暗部：5 块近黑灰，能分清几块 ≈ 屏幕黑位/对比度；
/// 2. 高光：5 块近白灰，全都糊成一片说明亮度太高；
/// 3. 白点：纯白 vs 245 白，应该能看出差别；
/// 4. 三原色：红绿蓝，判断有没有开护眼/夜间模式把颜色整个推掉。
///
/// 亮度用窗口亮度控制（不需要「修改系统设置」权限），退出页面自动恢复。
///
/// **限制**：厂商的显示模式（自然/标准/鲜艳/影院）和硬件白点，App 读不到也改不了，
/// 只能引导用户手动固定到「自然/标准」，并把状态记下来。
class ScreenCalibrationPage extends StatefulWidget {
  const ScreenCalibrationPage({super.key});

  @override
  State<ScreenCalibrationPage> createState() => _ScreenCalibrationPageState();
}

class _ScreenCalibrationPageState extends State<ScreenCalibrationPage> {
  int _card = 0;
  double _brightness = 0.5;
  bool _brightnessReady = false;
  String? _savedAt;

  static const String _fileName = 'screen_profile.json';

  @override
  void initState() {
    super.initState();
    _load();
    _loadBrightness();
  }

  @override
  void dispose() {
    // 离开页面就把窗口亮度还给系统，别让用户手机的亮度被 App 锁住
    ScreenControl.resetBrightness();
    super.dispose();
  }

  Future<void> _loadBrightness() async {
    final double value = await ScreenControl.getBrightness();
    if (!mounted) return;
    setState(() {
      _brightness = value;
      _brightnessReady = true;
    });
    await ScreenControl.setBrightness(value);
  }

  Future<void> _step(double delta) async {
    final double next = (_brightness + delta).clamp(0.02, 1.0);
    setState(() => _brightness = next);
    await ScreenControl.setBrightness(next);
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
      'brightness': _brightness,
      'card': _card,
    }));
    if (!mounted) return;
    setState(() => _savedAt = now);
    showSnack(context, '已记录：屏幕亮度 ' + (_brightness * 100).round().toString() + '%');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('屏幕校色'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          const Text(
            '没有测量仪器，只能做「人眼自检」。把屏幕固定到一个状态，再看色。',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          _brightnessBar(),
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
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: SizedBox(height: 200, child: _cardView()),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(_tip(),
              style: const TextStyle(fontSize: 13, height: 1.6)),
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
          _modeCard(),
          const SizedBox(height: AppSpacing.md),
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

  Widget _brightnessBar() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.brightness_6_outlined, size: 18),
              const SizedBox(width: 6),
              const Text('亮度（只影响本页）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                _brightnessReady
                    ? (_brightness * 100).round().toString() + '%'
                    : '…',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              IconButton.filledTonal(
                onPressed: _brightnessReady ? () => _step(-0.05) : null,
                icon: const Icon(Icons.remove),
                tooltip: '调暗 5%',
              ),
              Expanded(
                child: Slider(
                  value: _brightness,
                  min: 0.02,
                  onChanged: _brightnessReady
                      ? (double v) {
                          setState(() => _brightness = v);
                          ScreenControl.setBrightness(v);
                        }
                      : null,
                ),
              ),
              IconButton.filledTonal(
                onPressed: _brightnessReady ? () => _step(0.05) : null,
                icon: const Icon(Icons.add),
                tooltip: '调亮 5%',
              ),
            ],
          ),
          Text(
            '这是「窗口亮度」：只改本页面，退出自动恢复，也不需要修改系统设置权限。'
            '看色前建议先在系统里关掉「自动亮度」，否则系统会和你抢控制权。',
            style: TextStyle(
                fontSize: 11, height: 1.5, color: AppColors.sub(context)),
          ),
        ],
      ),
    );
  }

  Widget _modeCard() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('厂商显示模式：App 改不了，只能你自己固定',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          SizedBox(height: 6),
          Text(
            '每台手机的「自然 / 标准 / 鲜艳 / 影院」会直接改颜色，App 既读不到当前是哪档，'
            '也没法替你切。所以：\n'
            '· 先到系统设置里把色彩模式固定成「自然」或「标准」；\n'
            '· 关掉护眼模式、夜间模式、色弱模式；\n'
            '· 之后再回来看这三原色，应该是干净的红/绿/蓝。',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _cardView() {
    switch (_card) {
      case 0:
        return _strip(<int>[0, 4, 8, 12, 16], Colors.black);
      case 1:
        return _strip(<int>[255, 251, 247, 243, 239], Colors.white);
      case 2:
        return Row(
          children: <Widget>[
            Expanded(child: Container(color: const Color(0xFFFFFFFF))),
            Expanded(child: Container(color: const Color(0xFFF5F5F5))),
          ],
        );
      default:
        // 注意：ColoredBox 没有 child 时尺寸会塌成 0，这里必须用 Container + Expanded
        return Row(
          children: <Widget>[
            Expanded(child: Container(color: const Color(0xFFD62828))),
            Expanded(child: Container(color: const Color(0xFF2A9D3F))),
            Expanded(child: Container(color: const Color(0xFF1D4ED8))),
          ],
        );
    }
  }

  Widget _strip(List<int> values, Color background) {
    return Row(
      children: <Widget>[
        for (final int v in values)
          Expanded(
            child: Container(
              color: background,
              alignment: Alignment.center,
              child: Container(
                width: 60,
                height: 120,
                color: Color.fromARGB(255, v, v, v),
              ),
            ),
          ),
      ],
    );
  }

  String _tip() {
    switch (_card) {
      case 0:
        return '暗部：5 块灰从深到浅。调亮度到「能看清最左两块、但最左整块不发光」比较合适。'
            '如果 5 块糊成一片，判色会整体偏黑。';
      case 1:
        return '高光：5 块近白灰。如果右边 2-3 块分不出来，说明亮度太高、高光被压平了——'
            '看白色瓷砖时容易把「米白」看成「纯白」。往下调一档再试。';
      case 2:
        return '白点：左边纯白，右边 245 的近白。能看出差别说明高光余量还在；完全一样说明已经截断。';
      default:
        return '三原色：看红/绿/蓝是否「干净」。发青、发黄、发灰，多半是开了护眼/夜间/色弱模式，'
            '或者厂商色彩模式在「鲜艳」。';
    }
  }
}
