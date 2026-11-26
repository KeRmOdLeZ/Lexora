package com.lexora.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        if (intent != null && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            intent.data = null
            intent.action = Intent.ACTION_MAIN
        }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            return
        }
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DictExtractor.register(
            appContext = applicationContext,
            binaryMessenger = flutterEngine.dartExecutor.binaryMessenger
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DictExtractor.unregister()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
