package org.codeberg.theoden8.webspace

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "app.channel"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDemoMode" -> {
                    val demoMode = intent?.getBooleanExtra("DEMO_MODE", false) ?: false
                    result.success(demoMode)
                }
                else -> result.notImplemented()
            }
        }
    }
}
