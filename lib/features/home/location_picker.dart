import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// 光源 / 地点标签的选择器（采集时用，详情页改标签时也用同一个）。
///
/// 返回 null 表示用户取消；返回空串表示「清除标签」。
Future<String?> showLocationPicker(BuildContext context, {String? current}) async {
  const List<String> presets = <String>[
    '家里·顶灯',
    '家里·窗边自然光',
    '门店·射灯',
    '门店·顶灯',
    '室外',
  ];

  final String? picked = await showModalBottomSheet<String>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                current == null || current.isEmpty
                    ? '这张是在哪拍的？什么光？（可跳过）'
                    : '现在标的是：' + current,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          ...presets.map((String value) => ListTile(
                dense: true,
                leading: value == current
                    ? const Icon(Icons.check, size: 18, color: AppColors.success)
                    : const SizedBox(width: 18),
                title: Text(value, style: const TextStyle(fontSize: 14)),
                onTap: () => Navigator.pop(ctx, value),
              )),
          ListTile(
            dense: true,
            leading: const Icon(Icons.edit_outlined, size: 18),
            title: const Text('自定义…', style: TextStyle(fontSize: 14)),
            onTap: () => Navigator.pop(ctx, '__custom__'),
          ),
          if (current != null && current.isNotEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.close, size: 18),
              title: const Text('清除标签', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, ''),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_back, size: 18),
            title: const Text('算了', style: TextStyle(fontSize: 14)),
            onTap: () => Navigator.pop(ctx),
          ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return null;
  if (picked != '__custom__') return picked;

  final TextEditingController controller = TextEditingController();
  final String? custom = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('光源 / 地点'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '比如：门店东侧射灯'),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (custom == null) return null;
  return custom;
}
