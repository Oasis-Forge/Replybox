package com.oasisforge.replybox

import com.oasisforge.replybox.capture.CaptureChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The capture channels are the app's only platform surface. Registered per
        // engine and handed the application context, so nothing here outlives this
        // Activity by holding it.
        CaptureChannel.register(flutterEngine, applicationContext)
    }
}
