package com.listenjar.desktop;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.annotation.Keep;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashSet;
import java.util.Set;

/**
 * Installs ListenJar's own updates, for lib/updates.dart, which calls it
 * through the JNIgen bindings in lib/apk_installer.g.dart (tool/jnigen.dart
 * regenerates them). Dart checks listenjar/desktop's latest release, asks,
 * downloads the APK and checks its SHA-256; this checks that the APK is this
 * app, newer, for this Android and signed with the very certificates this
 * app is, and hands it to PackageInstaller.
 *
 * Android always asks the listener to confirm, as ReVanced Manager does:
 * once ListenJar is its own installer of record (Android 12+) it could
 * update silently, but it would vanish mid-use with nothing to reopen it.
 * Android stops the app to replace it, so success shows as the new version
 * starting.
 */
@Keep
public final class ApkInstaller {
    private ApkInstaller() {}

    static final String RELEASE_PACKAGE = "com.listenjar.desktop";

    /**
     * How an install went: `confirming`, `cancelled`, `refused` (the APK
     * isn't a ListenJar update from ListenJar's key) or `failed`, with why.
     */
    @Keep
    public interface Listener {
        void onStatus(String status, String message);
    }

    private static volatile Listener listener;

    /** A release build of com.listenjar.desktop: debug builds (.dev) don't update themselves. */
    public static boolean updatesItself(Context context) {
        return context.getPackageName().equals(RELEASE_PACKAGE)
            && (context.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0;
    }

    public static String version(Context context) throws PackageManager.NameNotFoundException {
        String name = own(context, 0).versionName;
        return name == null ? "" : name;
    }

    /** pubspec.yaml's build number, which release manifests compare. */
    public static long build(Context context) throws PackageManager.NameNotFoundException {
        return own(context, 0).getLongVersionCode();
    }

    /** Whether "Install unknown apps" allows ListenJar. */
    public static boolean canInstall(Context context) {
        return context.getPackageManager().canRequestPackageInstalls();
    }

    /** Opens ListenJar's "Install unknown apps" setting. */
    public static void askToInstall(Context context) {
        Intent intent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + context.getPackageName()));
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }

    /**
     * Checks [path] and commits it to PackageInstaller off the calling
     * thread (Flutter's UI thread is Android's main thread); [listener]
     * hears how it goes.
     */
    public static void install(Context context, String path, Listener listener) {
        ApkInstaller.listener = listener;
        Context app = context.getApplicationContext();
        new Thread(() -> {
            File apk = new File(path);
            try {
                check(app, apk);
            } catch (Exception e) {
                report("refused", e.getMessage() == null ? e.toString() : e.getMessage());
                return;
            }
            try {
                commit(app, apk);
            } catch (Exception e) {
                report("failed", e.getMessage() == null ? e.toString() : e.getMessage());
            }
        }, "ListenJar update").start();
    }

    private static PackageInfo own(Context context, int flags) throws PackageManager.NameNotFoundException {
        return context.getPackageManager().getPackageInfo(context.getPackageName(), flags);
    }

    /** Refuses an APK Android would refuse, or one not from ListenJar's key. */
    private static void check(Context context, File apk) throws PackageManager.NameNotFoundException {
        PackageInfo info = context.getPackageManager().getPackageArchiveInfo(apk.getPath(), PackageManager.GET_SIGNING_CERTIFICATES);
        if (info == null) throw new IllegalArgumentException("The download isn’t an app Android can read.");
        PackageInfo own = own(context, PackageManager.GET_SIGNING_CERTIFICATES);
        if (!own.packageName.equals(info.packageName)) throw new IllegalArgumentException("The download is " + info.packageName + ", not ListenJar.");
        if (info.getLongVersionCode() <= own.getLongVersionCode()) throw new IllegalArgumentException("The download isn’t newer than this version.");
        int minimum = info.applicationInfo == null ? 0 : info.applicationInfo.minSdkVersion;
        if (minimum > Build.VERSION.SDK_INT) throw new IllegalArgumentException("This version needs a newer Android.");
        Set<String> theirs = signers(info);
        if (theirs.isEmpty() || !theirs.equals(signers(own))) throw new IllegalArgumentException("The download isn’t signed with ListenJar’s key.");
    }

    private static Set<String> signers(PackageInfo info) {
        Set<String> set = new HashSet<>();
        if (info.signingInfo == null) return set;
        Signature[] signers = info.signingInfo.getApkContentsSigners();
        if (signers != null) for (Signature s : signers) set.add(s.toCharsString());
        return set;
    }

    private static void commit(Context context, File apk) throws Exception {
        PackageInstaller installer = context.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(context.getPackageName());
        params.setSize(apk.length());
        params.setInstallReason(PackageManager.INSTALL_REASON_USER);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) params.setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE);
        int id = installer.createSession(params);
        try (PackageInstaller.Session session = installer.openSession(id)) {
            try (OutputStream out = session.openWrite("base.apk", 0, apk.length()); InputStream in = new FileInputStream(apk)) {
                byte[] buffer = new byte[1 << 16];
                for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
                session.fsync(out);
            }
            // Mutable: PackageInstaller adds the status and its intent.
            PendingIntent status = PendingIntent.getBroadcast(
                context, id, new Intent(context, Status.class),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
            session.commit(status.getIntentSender());
        } catch (Exception e) {
            installer.abandonSession(id);
            throw e;
        }
    }

    private static void report(String status, String message) {
        Listener l = listener;
        if (l != null) l.onStatus(status, message);
    }

    /**
     * PackageInstaller's word on a session (AndroidManifest.xml): opens
     * Android's confirmation when it asks for one, and reports the rest.
     */
    @Keep
    public static final class Status extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
            String message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
            switch (status) {
                case PackageInstaller.STATUS_PENDING_USER_ACTION: {
                    Intent confirm = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                        ? intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent.class)
                        : intent.getParcelableExtra(Intent.EXTRA_INTENT);
                    if (confirm == null) {
                        report("failed", "Android didn’t ask to confirm.");
                        return;
                    }
                    context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    report("confirming", null);
                    return;
                }
                // This app's own process ends as Android replaces it, so
                // success rarely gets here.
                case PackageInstaller.STATUS_SUCCESS:
                    report("installed", null);
                    return;
                case PackageInstaller.STATUS_FAILURE_ABORTED:
                    report("cancelled", null);
                    return;
                default:
                    report("failed", message == null ? "Android couldn’t install it (" + status + ")." : message);
            }
        }
    }
}
