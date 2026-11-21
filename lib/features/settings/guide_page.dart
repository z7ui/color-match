import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 使用说明：拿什么、怎么拍、软件在比什么、这软件到底准到几分。
class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('怎么用'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          _step(
            context,
            '1',
            '准备一张白纸（不用整张入画）',
            '一张普通 A4 白纸、白卡、甚至白墙都行，越哑光越好（别用铜版纸、别用带格子的）。\n\n'
                '只要让纸的「一个白角」入镜就够了——大约占画面 1/5，不需要整张纸塞进画面。\n\n'
                '它的作用只是告诉软件「这里的光偏什么色」，不是对比对象。\n\n'
                '有条件就换 18% 灰卡或专业白卡：打印纸含荧光增白剂，在日光/射灯下会偏蓝，'
                '等于给整张照片带了一个固定偏差。同一张纸两趟都要带，别在家里用一张、到店里换另一张。',
          ),
          _step(
            context,
            '2',
            '怎么拍',
            '· 主体（瓷砖 / 门窗 / 小样）放画面中间，正对表面，别斜着拍\n'
                '· 白纸露一个角在左下角那块，别挡住主体\n'
                '· **别用变焦**（1x 以外都是裁切或换镜头，颜色会变）\n'
                '· 别开闪光灯；白纸别被压到纯白（亮了就压一点曝光）\n'
                '· 别让画面里同时有射灯和窗户光：混合光源下白点只能代表其中一种\n'
                '· 手机离主体的距离，两个地方要差不多（避免广角畸变+边缘色偏）',
          ),
          _step(
            context,
            '3',
            '两个地方拍法要一致',
            '家里拍一张、厂里拍一张，构图尽量接近：主体占画面大小差不多、白纸位置差不多、离得差不多。'
                '拍法越接近，对比越可信。',
          ),
          _step(
            context,
            '4',
            '标定：框选白纸（只记白点，不改照片）',
            '拍完后点「标定」，把画面里的白纸框进去。软件会读它的平均色，并检查四件事：\n'
                '· 够不够亮（低于 120 会提示：拉平别的照片时容易把高光拉爆）\n'
                '· 有没有过曝（最亮通道顶到 255 就测不准了）\n'
                '· 框里均不均匀（跨度 ≤10，否则有反光或阴影）\n'
                '· 这块白中不中性（通道差 ≤12，否则可能框到了带色的纸）\n\n'
                '**标定不会修改这张照片**——家里那张永远是原样，它是对比的基准。',
          ),
          _step(
            context,
            '5',
            '可选：同时标一块「已知物」= 自检',
            '在标定页打开「同时记录一块已知物」，再框一次灰卡中灰（或同一块样板、同一张名片）。\n\n'
                '两张照片里放**同一件东西**，软件就能算出：把它从工地的光线搬到家里的光线后，还差多少。'
                '这个差值就是**误差下限**——本次对比的分辨力。\n\n'
                '结果区会显示：`误差下限 ΔE 1.2　·　可信 3.6`。意思是 ΔE 里 1.2 是噪声，'
                '真实差异约 3.6；如果 ΔE 比误差下限还小，说明这次**分辨不出来**，不是「完全一样」。',
          ),
          _step(
            context,
            '6',
            '对比：软件比的是主体',
            '标定完点「对比」。软件取画面中心区域（也就是主体）的平均色，'
                '把工地那张搬到家里的光线里，再和家里的原图算 ΔE。\n\n'
                'ΔE 越小越像：<1 几乎看不出，1–2 细看能看出，2–5 明显不同，>5 是两个颜色。',
          ),
          const SizedBox(height: AppSpacing.md),
          _card(
            context,
            '换光源复检（不花钱，但最有用的自检）',
            '同一块样品，在家里顶灯、窗边自然光、门店射灯下各拍一张（记得每次给照片打上「光」的标签）。\n\n'
                '三张两两对比：如果 ΔE 都差不多，说明这块材料稳定；'
                '如果换一种光 ΔE 就变了 2 以上，那多半是**同色异谱**——'
                '两块材料在一种灯下同色、换一种灯就分家，任何软件都救不了，只能带实物回家看。',
            color: AppColors.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          _card(
            context,
            '几个容易踩的坑',
            '· 白纸被手挡住一半 → 白点算错，整张图偏色\n'
                '· 白纸在阴影里 → 提示「偏暗」，换了也不准\n'
                '· 白纸过曝成一片白 → 读数被压平，增益估小\n'
                '· 主体反光 → 换个角度，别正对灯\n'
                '· 广角贴着拍 → 边缘暗角 + 色偏，离远一点',
            color: AppColors.warning,
          ),
          const SizedBox(height: AppSpacing.md),
          _card(
            context,
            'A4 灰阶靶？这里用不上',
            '那张打了 25 个灰块的 A4 靶纸，是用来「诊断照片灰阶准不准」的（配脚本读 25 块、算光照梯度），'
                '要求整张纸入画、透视校正。\n\n'
                '这个 App 不做那件事——它只需要「一块白」定白点，把两个地方的光拉平。'
                '所以不用打印灰阶靶，更不用整张纸入画。',
            color: AppColors.divider,
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

  Widget _card(BuildContext context, String title, String body, {Color? color}) {
    final Color accent = color ?? AppColors.divider;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(
                  fontSize: 12, height: 1.7, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
