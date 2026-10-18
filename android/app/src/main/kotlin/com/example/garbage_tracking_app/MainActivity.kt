package com.example.garbage_tracking_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets a signed-in driver leave the app WITHOUT closing it: finishing the activity would stop GPS and
        // take the truck offline, whereas moving the task to the background keeps the tracking service running.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gt/app").setMethodCallHandler { call, result ->
            when (call.method) {
                "moveToBack" -> {
                    result.success(moveTaskToBack(true))
                }
                "isBatteryExempt" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.M || pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestBatteryExemption" -> {
                    try {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !pm.isIgnoringBatteryOptimizations(packageName)) {
                            val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            i.data = Uri.parse("package:$packageName")
                            startActivity(i)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
