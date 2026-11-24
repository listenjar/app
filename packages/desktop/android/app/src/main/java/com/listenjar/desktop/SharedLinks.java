package com.listenjar.desktop;

import android.content.Intent;
import android.net.Uri;
import androidx.annotation.Keep;
import java.util.ArrayList;

/**
 * Links shared to ListenJar, for lib/shared_links.dart, which calls this
 * through the JNIgen bindings in lib/shared_links.g.dart (tool/jnigen.dart
 * regenerates them): text from the share sheet, a YouTube link opened with
 * the app, or a {@code <scheme>://open?url=…} link. MainActivity hands over
 * each intent; the links wait here, even from before Dart runs, until Dart
 * takes them, which a ping tells it to do.
 */
@Keep
public final class SharedLinks {
    private SharedLinks() {}

    /** A link is waiting. Dart implements it, as an async listener. */
    @Keep
    public interface Listener {
        void arrived();
    }

    private static final ArrayList<String> waiting = new ArrayList<>();
    private static Listener listener;

    /** Pings {@code onArrived} for every link from now on, and once now if any wait. */
    public static void listen(Listener onArrived) {
        boolean any;
        synchronized (SharedLinks.class) {
            listener = onArrived;
            any = !waiting.isEmpty();
        }
        if (any) onArrived.arrived();
    }

    /** The links waiting, oldest first, which no longer wait. */
    public static synchronized String[] take() {
        String[] links = waiting.toArray(new String[0]);
        waiting.clear();
        return links;
    }

    static void add(Intent intent) {
        String text = null;
        if (intent == null) return;
        if (Intent.ACTION_SEND.equals(intent.getAction())) {
            text = intent.getStringExtra(Intent.EXTRA_TEXT);
        } else if (Intent.ACTION_VIEW.equals(intent.getAction())) {
            Uri data = intent.getData();
            if (data != null && ("https".equals(data.getScheme()) || "open".equals(data.getHost()))) text = data.toString();
        }
        if (text == null) return;
        Listener ping;
        synchronized (SharedLinks.class) {
            waiting.add(text);
            ping = listener;
        }
        if (ping != null) ping.arrived();
    }
}
