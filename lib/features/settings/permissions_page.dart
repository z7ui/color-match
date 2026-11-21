import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/app_theme.dart';

/// 权限页：列出软件实际要用的权限、为什么用、当前状态。
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  Map<Permission, PermissionStatus> _status = <Permission, PermissionStatus>{};
  bool _loading = true;

  static const List<_PermItem> _items = <_PermItem>[
    _PermItem(
      permission: Permission.camera,
      icon: Icons.camera_alt_outlined,
      title: '相机',
      reason: '拍照记录瓷砖 / 门窗。不授权就没法用相机，但可以从相册上传。',
      required: true,
    ),
    _PermItem(
      permission: Permission.photos,
      icon: Icons.photo_library_outlined,
      title: '相册（照片）',
      reason: '从相册选已有的照片。Android 13 起系统用「照片选择器」，只会给你选中的那张，'
          '不会读整个相册。',
      required: false,
    ),
    _PermItem(
      permission: Permission.storage,
      icon: Icons.folder_outlined,
      title: '存储（旧系统）',
      reason: 'Android 12 及以下选相册图片时需要。Android 13 起不再需要。',
      required: false,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    // 只查状态，不主动弹窗
    final Map<Permission, PermissionStatus> result =
        <Permission, PermissionStatus>{
      Permission.camera: await Permission.camera.status,
      Permission.photos: await Permission.photos.status,
      Permission.storage: await Permission.storage.status,
    };
    if (!mounted) return;
    setState(() {
      _status = result;
      _loading = false;
    });
  }

  Future<void> _ask(Permission permission) async {
    final PermissionStatus result = await permission.request();
    if (!mounted) return;
    setState(() => _status = <Permission, PermissionStatus>{
          ..._status,
          permission: result,
        });
    if (result.isPermanentlyDenied) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('需要到系统设置里打开'),
          content: const Text('这个权限被永久拒绝了。点「打开设置」，在应用权限里手动允许。'),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                openAppSettings();
              },
              child: const Text('打开设置'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('权限'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: <Widget>[
                const Text(
                  '这些权限只在对应功能里用，照片和对比记录都存在手机本地，不上传。',
                  style: TextStyle(fontSize: 12, height: 1.6, color: AppColors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.lg),
                ..._items.map(_row),
                const SizedBox(height: AppSpacing.lg),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Row(
                          children: <Widget>[
                            Icon(Icons.info_outline, size: 18),
                            SizedBox(width: 6),
                            Text('关于「存储」',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '导出时会存两份：\n\n'
                          '1. 相册「ColorMatch」相簿（长期，卸载不丢）\n'
                          '   Android 10+ 不需要权限；Android 9 及以下需要上表的「存储」权限。\n\n'
                          '2. 应用目录（临时，卸载即删）\n'
                          '   Android/data/com.z7ui.color_match/files/ColorMatch/\n\n'
                          '相册那份用来长期留底，应用目录那份用于 App 内快速查看。',
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.7,
                              color: AppColors.sub(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _row(_PermItem item) {
    final PermissionStatus status =
        _status[item.permission] ?? PermissionStatus.denied;
    final bool granted = status.isGranted || status.isLimited;
    final Color color = granted
        ? AppColors.success
        : (status.isPermanentlyDenied ? AppColors.danger : AppColors.warning);

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(item.icon, size: 22),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(item.title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      if (item.required) ...<Widget>[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('必需',
                              style: TextStyle(
                                  fontSize: 10, color: AppColors.primary)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(item.reason,
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: AppColors.sub(context))),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Icon(
                        granted
                            ? Icons.check_circle
                            : (status.isPermanentlyDenied
                                ? Icons.block
                                : Icons.error_outline),
                        size: 14,
                        color: color,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        granted
                            ? '已允许'
                            : (status.isPermanentlyDenied ? '被永久拒绝' : '未允许'),
                        style: TextStyle(fontSize: 12, color: color),
                      ),
                      const Spacer(),
                      if (!granted)
                        TextButton(
                          onPressed: () => status.isPermanentlyDenied
                              ? openAppSettings()
                              : _ask(item.permission),
                          child: Text(status.isPermanentlyDenied ? '打开设置' : '去授权'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermItem {
  const _PermItem({
    required this.permission,
    required this.icon,
    required this.title,
    required this.reason,
    required this.required,
  });

  final Permission permission;
  final IconData icon;
  final String title;
  final String reason;
  final bool required;
}
