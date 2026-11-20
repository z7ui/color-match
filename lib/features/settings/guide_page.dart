import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 使用说明：告诉用户拿什么、怎么拍、软件在比什么。
class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, '怎么用'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          _step(
            context,
            '1',
            '准备一张白纸',
            'A4 白纸或灰卡都行，越哑光越好（别用铜版纸、别用带格子的）。'
                '这张纸的作用是告诉软件「这里的光是什么颜色」，它不是对比对象。',
          ),
          _step(
            context,
            '2',
            '怎么拍',
            '· 主体（瓷砖 / 门窗 / 小样）放画面中间\n'
                '· 白纸放左下角，别挡住主体\n'
                '· 光从两侧来，不要单侧打光、不要开闪光灯\n'
                '· 关掉 HDR、AI 摄影、夜景模式',
          ),
          _step(
            context,
            '3',
            '两个地方拍法要一致',
            '家里拍一张、厂里拍一张，构图尽量接近：'
                '主体占画面大小差不多、白纸位置差不多、手机离得差不多。'
                '拍法越接近，对比越可信。',
          ),
          _step(
            context,
            '4',
            '标定：框选白纸',
            '拍完后点右上角的裁剪图标，把画面里的白纸框进去。'
                '软件会读它的平均色，并检查两件事：\n'
                '· 白纸够不够亮（≥235，否则是欠曝）\n'
                '· 框里均不均匀（跨度 ≤15，否则有反光或阴影）',
          ),
          _step(
            context,
            '5',
            '对比：软件比的是主体',
            '标定完点「对比」。软件取画面中心区域（也就是主体）的平均色，'
                '把目标图搬到参照图的光线里，再算 ΔE。\n\n'
                'ΔE 越小越像：<1 几乎看不出，1–2 细看能看出，2–5 明显不同，>5 是两个颜色。',
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('几个容易踩的坑',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                SizedBox(height: 8),
                Text(
                  '· 白纸被手挡住一半 → 白点算错，整张图偏色\n'
                  '· 白纸在阴影里 → 软件会提示「白参考偏低」\n'
                  '· 主体反光 → 换个角度，别正对灯\n'
                  '· 两个地方用了不同的灯 → 这正是要修的东西，前提是白纸都拍清楚',
                  style: TextStyle(fontSize: 13, height: 1.7),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const Text(
            '这个工具只能修「光」，修不了「材质」。\n'
            '如果两块砖在同样光线下 ΔE 还是很大，那就是真的不是一个颜色。',
            style: TextStyle(fontSize: 12, height: 1.7, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _step(
      BuildContext context, String index, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(index,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(body,
                    style: const TextStyle(
                        fontSize: 13, height: 1.7, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
