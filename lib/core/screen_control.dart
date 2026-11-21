import 'package:flutter/services.dart';

/// 屏幕亮度控制（窗口级，不需要权限）。
///
/// 平台侧用 `WindowManager.LayoutParams.screenBrightness`，
/// 只影响本 App 的窗口，退出页面恢复跟随系统。
class ScreenControl {
  ScreenControl._();

  static const MethodChannel _channel =
      MethodChannel('com.z7ui.color_match/screen');

  /// 当前亮度（0.02..1.0 的相对值；非窗口亮度时读系统亮度近似值）。
  static Future<double> getBrightness() async {
    try {
      final double? value =
          (await _channel.invokeMethod<double>('getBrightness'))?.toDouble();
      return (value ?? 0.5).clamp(0.02, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  static Future<void> setBrightness(double value) async {
    try {
      await _channel.invokeMethod<double>(
          'setBrightness', value.clamp(0.02, 1.0));
    } catch (_) {}
  }

  /// 恢复跟随系统亮度。
  static Future<void> resetBrightness() async {
    try {
      await _channel.invokeMethod<bool>('resetBrightness');
    } catch (_) {}
  }
}
