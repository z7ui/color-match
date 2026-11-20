import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_theme.dart';
import '../../core/config.dart';
import '../../core/net.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  bool _checking = false;
  String? _updateText;
  String? _announcement;

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _updateText = null;
    });
    final Map<String, dynamic>? json =
        await fetchJson('${AppConfig.defaultBaseUrl}${AppConfig.versionPath}');
    if (!mounted) return;
    if (json == null) {
      setState(() {
        _checking = false;
        _updateText = '没拉到版本清单（服务器还没放，或网络不通）';
      });
      return;
    }
    final int remote = (json['versionCode'] as num?)?.toInt() ?? 0;
    setState(() {
      _checking = false;
      _updateText = remote > AppConfig.buildNumber
          ? '发现新版本 v${json['version']}：${json['notes'] ?? ''}'
          : '已是最新版本（v${AppConfig.appVersion}）';
    });
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
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, '关于'),
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
                Text('v${AppConfig.appVersion} (${AppConfig.buildNumber})',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
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
