import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 导出目录：优先放应用外部目录（文件管理器能进 Android/data 找到），
/// 拿不到时退回应用文档目录。
///
/// 路径形如：
///   /storage/emulated/0/Android/data/com.z7ui.color_match/files/ColorMatch/
Future<Directory> exportDir() async {
  Directory? base;
  try {
    base = await getExternalStorageDirectory();
  } catch (_) {
    base = null;
  }
  base ??= await getApplicationDocumentsDirectory();

  final Directory dir = Directory(p.join(base.path, 'ColorMatch'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// 给用户看的短路径（去掉 /storage/emulated/0 前缀）。
String prettyPath(String fullPath) {
  return fullPath
      .replaceFirst(RegExp(r'^/storage/emulated/0/'), '内部存储/')
      .replaceFirst(RegExp(r'^/data/user/0/[^/]+/'), '')
      .replaceFirst(RegExp(r'^/data/data/[^/]+/'), '');
}

/// 存到相册（Pictures/ColorMatch），卸载 App 不会删。
/// 返回 true 表示已进相册。
Future<bool> saveToGallery(String filePath) async {
  try {
    final bool has = await Gal.hasPermission(toAlbum: true);
    if (!has) {
      final bool granted = await Gal.requestPermission(toAlbum: true);
      if (!granted) return false;
    }
    await Gal.putImage(filePath, album: 'ColorMatch');
    return true;
  } catch (_) {
    return false;
  }
}
