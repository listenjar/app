package com.listenjar.desktop

import android.content.Intent
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity shares one Flutter engine with the playback service,
// so the player keeps going when the activity goes away.
//
// Links shared to ListenJar go to lib/shared_links.dart on the
// listenjar/links channel: text from the share sheet, a YouTube link opened
// with the app, or a <scheme>://open?url=… link. One that arrives before Dart
// listens waits until Dart asks for `pending`.
//
// In-app updates are Updates.kt's, on listenjar/updates.
class MainActivity : AudioServiceActivity() {
    private var links: MethodChannel? = null
    private var updates: Updates? = null
    private val pending = mutableListOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        links = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "listenjar/links").apply {
            setMethodCallHandler { call, result ->
                if (call.method != "pending") return@setMethodCallHandler result.notImplemented()
                result.success(pending.toList())
                pending.clear()
            }
        }
        updates = Updates(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        updates?.dispose()
        updates = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        updates?.resumed()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity has already passed its intent on.
        if (savedInstanceState == null) take(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        take(intent)
    }

    private fun take(intent: Intent?) {
        val text = when (intent?.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            Intent.ACTION_VIEW -> intent.data?.takeIf { it.scheme == "https" || it.host == "open" }?.toString()
            else -> null
        } ?: return
        val channel = links ?: return run { pending.add(text) }
        channel.invokeMethod("open", text, object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(code: String, message: String?, details: Any?) { pending.add(text) }
            override fun notImplemented() { pending.add(text) }
        })
    }
}
