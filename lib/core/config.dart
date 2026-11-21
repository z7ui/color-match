/// 全局常量：版本、服务器、文件目录。
class AppConfig {
  AppConfig._();

  static const String appName = '选色助手';
  static const String appVersion = '0.1.19';
  static const int buildNumber = 20;

  /// 检查更新 / 公告复用同一台服务器（和余砖管家同一个后端）。
  static const String defaultBaseUrl = 'https://www.z7ui.cn/tile-api';

  /// APK 清单路径（发布时放到这个位置）。
  static const String versionPath = '/apk/color-match/version.json';

  /// 公告路径。
  static const String announcementPath = '/api/announcement';

  /// 数据库文件名。
  static const String dbName = 'color_match.db';

  /// 原图目录。
  static const String imagesDir = 'captures';
}
