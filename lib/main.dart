import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_theme.dart';
import 'core/config.dart';
import 'core/diag.dart';
import 'features/home/home_page.dart';

/// ADB 后门入口：MainActivity 收到 action=com.z7ui.color_match.DIAG 的 intent 后，
/// 把 --es cmd 的值通过这个 channel 交给 Dart。
const MethodChannel _diagChannel = MethodChannel('com.z7ui.color_match/diag');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _diagChannel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'run' && call.arguments is String) {
      Diag.pending.value = call.arguments as String;
    }
    return null;
  });
  runApp(const ColorMatchApp());
}

class ColorMatchApp extends StatelessWidget {
  const ColorMatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const HomePage(),
    );
  }
}
