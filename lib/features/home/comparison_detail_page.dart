import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/storage.dart';
import '../viewer/photo_view_page.dart';

/// 单组对比的详情页：三张图 + 这一组用到的所有参数。
///
/// 存在的意义：列表里的结果区是「横向翻页」，看不清数据来源；
/// 这一页把白点、已知物、误差下限、光源标签、时间全部摊开，可单独导出/删除。
class ComparisonDetailPage extends StatefulWidget {
  const ComparisonDetailPage({
    super.key,
    required this.sessionName,
    required this.reference,
    required this.target,
    required this.comparison,
  });

  final String sessionName;
  final Capture reference;
  final Capture target;
  final Comparison comparison;

  @override
  State<ComparisonDetailPage> createState() => _ComparisonDetailPageState();
}

class _ComparisonDetailPageState extends State<ComparisonDetailPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final Comparison c = widget.comparison;
    final Capture ref = widget.reference;
    final Capture target = widget.target;
    return Scaffold(
      appBar: buildAppBar('对比详情'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: <Widget>[
          _imageBlock(
            context,
            title: '家里（基准）',
            subtitle: ref.location.isEmpty ? '原图，未做任何处理' : ref.location,
            path: ref.imagePath,
            accent: AppColors.primary,
          ),
          _imageBlock(
            context,
            title: '工地（原图）',
            subtitle: target.location.isEmpty ? '拍摄原始画面' : target.location,
            path: target.imagePath,
            accent: AppColors.warning,
          ),
          _imageBlock(
            context,
            title: '工地（拉到家里光线后）',
            subtitle: '用于和左边那张比颜色',
            path: c.processedPath,
            accent: AppColors.success,
          ),
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('这一组的数据',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  _kv('校正后 ΔE', c.deltaE.toStringAsFixed(2),
                      color: AppColors.success),
                  _kv('校正前 ΔE', c.deltaEBefore.toStringAsFixed(2)),
                  _kv('改善',
                      (c.improvement * 100).toStringAsFixed(0) + '%'),
                  if (c.hasErrorFloor) ...<Widget>[
                    _kv('误差下限 ΔE', c.errorFloor.toStringAsFixed(2),
                        color: c.errorFloor > 5
                            ? AppColors.danger
                            : AppColors.warning),
                    _kv('可信差异', c.trustworthy.toStringAsFixed(2),
                        color: AppColors.primary),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 6),
                      child: Text(
                        c.errorFloor > 5
                            ? '误差下限偏大：两块已知物对不上，这一组的 ΔE 不可信，建议重拍。'
                            : 'ΔE 里约有 ' +
                                c.errorFloor.toStringAsFixed(2) +
                                ' 是噪声，扣掉后约 ' +
                                c.trustworthy.toStringAsFixed(2) +
                                '。ΔE 小于误差下限时说明「分辨不出来」，不是「一样」。',
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: AppColors.sub(context)),
                      ),
                    ),
                  ],
                  const Divider(height: 24),
                  _kv('家里白点', _white(ref)),
                  _kv('工地白点', _white(target)),
                  if (ref.hasChecker) _kv('家里已知物', _checker(ref)),
                  if (target.hasChecker) _kv('工地已知物', _checker(target)),
                  _kv('家里光源', ref.location.isEmpty ? '未标注' : ref.location),
                  _kv('工地光源', target.location.isEmpty ? '未标注' : target.location),
                  if (target.usedTorch || ref.usedTorch)
                    _kv('补光',
                        (ref.usedTorch ? '家里开了' : '') +
                            (target.usedTorch ? '工地开了' : ''),
                        color: AppColors.warning),
                  _kv('对比时间', _formatDate(c.createdAt)),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _share,
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('分享成图'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _saveToGallery,
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('存相册'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('删除这条对比（保留照片）'),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          ),
        ],
      ),
    );
  }

  Widget _imageBlock(BuildContext context,
      {required String title,
      required String subtitle,
      required String path,
      required Color accent}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 3,
                height: 16,
                color: accent,
              ),
              const SizedBox(width: 6),
              Text(title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(subtitle,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.sub(context))),
            ],
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => PhotoViewPage(
                items: <String>[
                  widget.reference.imagePath,
                  widget.target.imagePath,
                  widget.comparison.processedPath,
                ],
                captions: const <String>[
                  '家里（基准）',
                  '工地（原图）',
                  '工地（拉到家里光线后）',
                ],
                initialIndex: path == widget.reference.imagePath
                    ? 0
                    : path == widget.target.imagePath
                        ? 1
                        : 2,
              ),
            )),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: Image.file(
                File(path),
                width: double.infinity,
                height: 200,
                fit: BoxFit.cover,
                cacheWidth: 1080,
                errorBuilder: (_, _, _) => Container(
                  height: 120,
                  alignment: Alignment.center,
                  color: AppColors.line(context),
                  child: const Text('图片读取失败',
                      style: TextStyle(color: AppColors.textHint)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String key, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(key,
                style: TextStyle(
                    fontSize: 12, color: AppColors.sub(context))),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color ?? AppColors.text)),
          ),
        ],
      ),
    );
  }

  String _white(Capture c) => c.isCalibrated
      ? '(' +
          c.whiteR.toString() +
          ', ' +
          c.whiteG.toString() +
          ', ' +
          c.whiteB.toString() +
          ')'
      : '未标定';

  String _checker(Capture c) => c.hasChecker
      ? '(' +
          c.checkR.toString() +
          ', ' +
          c.checkG.toString() +
          ', ' +
          c.checkB.toString() +
          ')'
      : '未标';

  String _formatDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return t.year.toString() +
        '-' +
        two(t.month) +
        '-' +
        two(t.day) +
        ' ' +
        two(t.hour) +
        ':' +
        two(t.minute);
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      await SharePlus.instance.share(ShareParams(
          files: <XFile>[XFile(widget.comparison.processedPath)]));
    } catch (error) {
      if (mounted) showSnack(context, '分享失败：' + error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToGallery() async {
    setState(() => _busy = true);
    try {
      final bool ok = await saveToGallery(widget.comparison.processedPath);
      if (!mounted) return;
      showSnack(context, ok ? '已存到相册' : '存相册失败（权限或空间）', error: !ok);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除这条对比？'),
        content: const Text('只删对比结果和成图，三张照片都保留。'),
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
    // 由调用方（会话页）删文件 + 刷新，这里只负责返回结果
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }
}
