package com.micago.message.mica_go

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "micago/keepalive"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> { startKeepAlive(); result.success(true) }
                    "stop" -> { stopKeepAlive(); result.success(true) }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startKeepAlive() {
        val intent = Intent(this, KeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopKeepAlive() {
        val intent = Intent(this, KeepAliveService::class.java).apply {
            action = KeepAliveService.ACTION_STOP
        }
        startService(intent)
    }
}
