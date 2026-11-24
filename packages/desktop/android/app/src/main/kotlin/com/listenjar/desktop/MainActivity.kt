package com.listenjar.desktop

import android.content.Intent
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity shares one Flutter engine with the playback service,
// so the player keeps going when the activity goes away.
//
// Links shared to ListenJar wait in SharedLinks.java for
// lib/shared_links.dart, which takes them over JNI.
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity has already passed its intent on.
        if (savedInstanceState == null) SharedLinks.add(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        SharedLinks.add(intent)
    }
}
