import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_theme.dart';
import '../../core/config.dart';
import '../../core/net.dart';
import '../capture/color_card_page.dart';
import 'backup_page.dart';
import 'diag_page.dart';
import 'permissions_page.dart';
import 'screen_calibration_page.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  bool _checking = false;
  String? _updateText;
  String? _announcement;
  int _versionTaps = 0;

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _updateText = null;
    });
    final Map<String, dynamic>? json =
        await fetchJson('${AppConfig.defaultBaseUrl}${AppConfig.versionPath}');
    if (!mounted) return;
    setState(() => _checking = false);

    if (json == null) {
      setState(() => _updateText = '没拉到版本清单（服务器还没放，或网络不通）');
      return;
    }

    // 服务器清单里字段叫 versionCode 或 buildNumber 都要认（余砖管家那边用的是后者）
    final int remote = ((json['versionCode'] ?? json['buildNumber']) as num?)?.toInt() ?? 0;
    final String version = '${json['version'] ?? ''}';
    final String notes = '${json['notes'] ?? ''}';
    final String? apkUrl = json['apk_url'] as String?;

    if (remote <= AppConfig.buildNumber) {
      setState(() => _updateText = '已是最新版本（v${AppConfig.appVersion}）');
      return;
    }

    setState(() => _updateText = '发现新版本 v$version');
    if (!mounted) return;

    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('发现新版本 v$version'),
        content: Text(notes.isEmpty ? '有新版本可用。' : notes),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('以后再说')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去下载'),
          ),
        ],
      ),
    );
    if (go == true && apkUrl != null && apkUrl.isNotEmpty) {
      await _open(apkUrl);
    }
  }

  Future<void> _loadAnnouncement() async {
    final Map<String, dynamic>? json = await fetchJson(
        '${AppConfig.defaultBaseUrl}${AppConfig.announcementPath}?app_version=${AppConfig.appVersion}');
    if (!mounted) return;
    final Object? item = json?['announcement'];
    if (item is Map) {
      final Map<dynamic, dynamic> map = item;
      setState(() => _announcement = '${map['title'] ?? ''}\n${map['body'] ?? ''}');
    } else {
      setState(() => _announcement = '当前没有公告');
    }
  }

  Future<void> _open(String url) async {
    final Uri uri = Uri.parse(url);
    try {
      // 直接 launch，不看 canLaunchUrl：Android 11+ 的包可见性会让预判误报 false
      final bool ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {}

    // 打不开就复制地址，让用户自己粘到浏览器
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    showSnack(context, '打不开浏览器，链接已复制，请粘到浏览器打开', error: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar('关于'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          const SizedBox(height: AppSpacing.lg),
          Center(
            child: Column(
              children: <Widget>[
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(Icons.palette_outlined,
                      size: 38, color: AppColors.primary),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text('选色助手',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                const Text('装修选色对比 · 把不同环境的光拉平',
                    style:
                        TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () {
                    _versionTaps++;
                    if (_versionTaps >= 7) {
                      _versionTaps = 0;
                      Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const DiagPage()));
                    } else if (_versionTaps == 3) {
                      showSnack(context, '再点 4 次进入诊断（不需要 ADB）');
                    }
                  },
                  child: Text('v' + AppConfig.appVersion + ' (' + AppConfig.buildNumber.toString() + ')',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: const Text('检查更新'),
                  subtitle: _updateText == null
                      ? const Text('从服务器拉取最新版本清单')
                      : Text(_updateText!),
                  trailing: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right),
                  onTap: _checking ? null : _checkUpdate,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.campaign_outlined),
                  title: const Text('公告'),
                  subtitle: Text(_announcement ?? '点一下看看服务器有没有公告'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _loadAnnouncement,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('权限'),
                  subtitle: const Text('相机 / 相册，各自用在哪'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const PermissionsPage()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('数据管理'),
                  subtitle: const Text('备份 / 恢复 / 导出 CSV、JSON'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const BackupPage()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('相机色彩校正（24 色卡）'),
                  subtitle: const Text('可选：需要 24 色卡，没有可以跳过，不影响使用'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const ColorCardPage()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.smartphone_outlined),
                  title: const Text('屏幕自检'),
                  subtitle: const Text('暗部 / 高光 / 白点 / 三原色，看看屏幕状态'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const ScreenCalibrationPage()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('开源协议'),
                  subtitle: const Text('GPL-3.0'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('博客'),
                  subtitle: const Text('www.z7ui.cn'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _open('https://www.z7ui.cn/'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          const Text(
            '所有照片和对比记录都存在手机内部存储，不会上传到第三方。',
            style: TextStyle(fontSize: 12, height: 1.6, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
