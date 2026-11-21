package com.z7ui.color_match

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 两个平台通道：
 *
 * 1. `com.z7ui.color_match/diag` —— 后门：ADB 意图带来的命令交给 Dart 执行。
 * 2. `com.z7ui.color_match/screen` —— 屏幕亮度控制（窗口级，不需要 WRITE_SETTINGS）。
 *
 * 亮度说明：窗口亮度是 0..1 的相对值，只影响本 App 这个窗口，退出页面恢复 -1（跟随系统）。
 * 它不等同于系统亮度，也不会改别人的亮度；这样既不用申请"修改系统设置"权限，
 * 又能在看色时把亮度钉在一个固定值。
 */
class MainActivity : FlutterActivity() {

    private var diagChannel: MethodChannel? = null
    private var screenChannel: MethodChannel? = null
    private var pendingCommand: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        diagChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.z7ui.color_match/diag"
        )
        pendingCommand?.let { deliver(it) }

        screenChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.z7ui.color_match/screen"
        )
        screenChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getBrightness" -> result.success(currentBrightness())
                "setBrightness" -> {
                    val value = (call.arguments as? Number)?.toFloat() ?: 0.5f
                    applyBrightness(value)
                    result.success(value)
                }
                "resetBrightness" -> {
                    applyBrightness(-1f)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun currentBrightness(): Double {
        val windowValue = window?.attributes?.screenBrightness ?: -1f
        if (windowValue >= 0f) return windowValue.toDouble()
        return try {
            val system = Settings.System.getInt(
                contentResolver,
                Settings.System.SCREEN_BRIGHTNESS
            )
            (system / 255.0).coerceIn(0.02, 1.0)
        } catch (e: Exception) {
            0.5
        }
    }

    private fun applyBrightness(value: Float) {
        runOnUiThread {
            val attrs = window.attributes
            attrs.screenBrightness = if (value < 0f) -1f else value.coerceIn(0.02f, 1f)
            window.attributes = attrs
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.let { handleIntent(it) }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action != "com.z7ui.color_match.DIAG") return
        val command = intent.getStringExtra("cmd") ?: "help"
        deliver(command)
    }

    private fun deliver(command: String) {
        val ch = diagChannel
        if (ch == null) {
            pendingCommand = command
            return
        }
        ch.invokeMethod("run", command)
    }
}
