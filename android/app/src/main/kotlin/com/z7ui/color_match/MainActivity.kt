package com.z7ui.color_match

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 后门入口（诊断用）：
 *
 *   adb shell am start -a com.z7ui.color_match.DIAG \
 *     -n com.z7ui.color_match/.MainActivity --es cmd stats
 *
 * 收到后把 --es cmd 的值通过 channel 交给 Dart 执行，结果显示在 App 的对话框里。
 * 应用已经在后台时走 onNewIntent（launchMode 是 singleTop）。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var pendingCommand: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.z7ui.color_match/diag"
        )
        pendingCommand?.let { deliver(it) }
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
        val ch = channel
        if (ch == null) {
            pendingCommand = command
            return
        }
        ch.invokeMethod("run", command)
    }
}
