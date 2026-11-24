// Android's in-app updates, the APK's Sparkle: ListenJar isn't in a store, so
// it reads the Android manifest of listenjar/desktop's latest GitHub release
// (tool/release.ts publishes it beside the APK, and makes a release the
// latest only once everything is up):
//
//   https://github.com/listenjar/desktop/releases/latest/download/manifest-android.json
//
// once a day while automatic checks are on, or when asked. A newer build asks
// the listener (UpdatePrompt), downloads the APK into the cache, checks its
// length and SHA-256 against the manifest, and hands it to ApkInstaller.java
// through JNI (apk_installer.g.dart, tool/jnigen.dart), which checks it is
// this app, newer and signed with this app's own certificates before
// Android's installer asks to confirm. Android itself refuses an update from
// another key, so the APK's signature is what Sparkle's Ed25519 is on macOS.
//
// The answers live in updates.json in the support directory: automatic
// checks, when it last looked, the build the listener skipped, and the APK
// already downloaded (an update survives Android 11 stopping the app when
// "Install unknown apps" is granted).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:jni/jni.dart';
import 'package:jni_flutter/jni_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'apk_installer.g.dart';
import 'log.dart';

/// listenjar/desktop's releases. A test build can point elsewhere with
/// `--dart-define=LISTENJAR_RELEASES=http://10.0.2.2:8000` (the emulator's
/// host), serving releases/latest/download/manifest-android.json and
/// `releases/download/<tag>/<asset>` as GitHub does.
const _releases = String.fromEnvironment('LISTENJAR_RELEASES', defaultValue: 'https://github.com/listenjar/desktop');
const _feed = '$_releases/releases/latest/download/manifest-android.json';
const _download = '$_releases/releases/download';
const _daily = Duration(days: 1);

/// A release from its manifest.
typedef ApkRelease = ({String version, int build, String tag, String asset, int length, String sha256});

/// Where an update stands, for the settings row.
typedef ApkUpdateState = ({String version, bool available, bool automatic, bool busy, String? status});

/// This app and its update, once [startApkUpdates] has looked.
final apkUpdates = ValueNotifier<ApkUpdateState?>(null);

/// A newer release waiting for the listener's answer (UpdatePrompt).
final apkOffer = ValueNotifier<ApkRelease?>(null);

final _log = Logger('updates');

final Context _context = androidApplicationContext.as(Context.type);
int _build = 0;
Map<String, Object?> _prefs = {};
late final File _prefsFile;
late final Directory _cache;
CancellationToken? _working;
Timer? _timer;
ApkInstaller$Listener? _listener;

/// The release ApkInstaller is installing.
ApkRelease? _installing;

void _set({bool? busy, Object? status = _same}) {
  final s = apkUpdates.value!;
  apkUpdates.value = (
    version: s.version,
    available: s.available,
    automatic: _prefs['automatic'] != false,
    busy: busy ?? s.busy,
    status: identical(status, _same) ? s.status : status as String?,
  );
}

const _same = Object();

/// Reads this app's version and the saved answers, offers an update already
/// downloaded, and checks once a day while automatic checks are on.
Future<void> startApkUpdates() async {
  final available = ApkInstaller.updatesItself(_context);
  final version = ApkInstaller.version(_context)?.toDartString(releaseOriginal: true) ?? '';
  _build = ApkInstaller.build(_context);
  _prefsFile = File('${(await getApplicationSupportDirectory()).path}/updates.json');
  _cache = Directory('${(await getApplicationCacheDirectory()).path}/updates');
  try {
    _prefs = (jsonDecode(await _prefsFile.readAsString()) as Map).cast();
  } on Object {
    _prefs = {};
  }
  apkUpdates.value = (version: version, available: available, automatic: _prefs['automatic'] != false, busy: false, status: null);
  _log.info('${apkUpdates.value}');
  if (!available) return;
  final downloaded = _release(_prefs['downloaded']);
  if (downloaded != null && downloaded.build > _build && await _verified(downloaded)) {
    apkOffer.value = downloaded;
  } else {
    await _forget();
  }
  _timer = Timer.periodic(const Duration(hours: 1), (_) => unawaited(_checkIfDue()));
  await _checkIfDue();
}

Future<void> _checkIfDue() async {
  if (_prefs['automatic'] == false || _working != null) return;
  final checked = DateTime.tryParse(_prefs['checkedAt'] as String? ?? '');
  if (checked != null && DateTime.now().difference(checked) < _daily) return;
  await checkApkUpdate(manual: false);
}

Future<void> setApkAutomatic(bool enabled) async {
  _prefs['automatic'] = enabled;
  await _save();
  _set();
  if (enabled) await _checkIfDue();
}

/// Looks for a newer release. Asked for, it offers even a skipped version and
/// says when there is none; while an update downloads, it stops it instead.
Future<void> checkApkUpdate({bool manual = true}) async {
  if (_working case final working?) {
    if (manual) working.cancel();
    return;
  }
  final token = _working = CancellationToken().merge(TimeoutCancellationToken(const Duration(seconds: 30)));
  if (manual) _set(busy: true, status: 'Checking…');
  try {
    final response = await http.get(Uri.parse(_feed)).asCancellable(token);
    if (response.statusCode != 200) throw HttpException('GitHub answered ${response.statusCode}');
    final release = _release(jsonDecode(response.body));
    if (release == null) throw const FormatException('The release manifest is not for Android');
    _prefs['checkedAt'] = DateTime.now().toUtc().toIso8601String();
    await _save();
    _log.info('latest ${release.version} (${release.build}); this is $_build');
    if (release.build <= _build) {
      _set(busy: false, status: manual ? 'This is the newest version.' : null);
    } else {
      _set(busy: false, status: null);
      if (manual || _prefs['skipped'] != release.build) apkOffer.value = release;
    }
  } on Object catch (e) {
    _log.warning('check failed: $e');
    _set(busy: false, status: manual ? 'Couldn’t check: ${_why(e)}' : null);
  } finally {
    _working = null;
  }
}

/// The listener skipped [release]: automatic checks don't offer it again.
Future<void> skipApkUpdate(ApkRelease release) async {
  _prefs['skipped'] = release.build;
  await _save();
}

/// Downloads [release] (unless it already is), checks it, and installs it:
/// Android asks to confirm, after "Install unknown apps" if ListenJar
/// hasn't got it yet. Tapping the settings row while it downloads stops it.
Future<void> installApkUpdate(ApkRelease release) async {
  if (_working != null) return;
  final token = _working = CancellationToken();
  try {
    final apk = await _downloaded(release, token);
    if (!ApkInstaller.canInstall(_context)) {
      _set(status: 'Allow ListenJar to install apps, then come back.');
      ApkInstaller.askToInstall(_context);
      await _resumed().asCancellable(token);
      if (!ApkInstaller.canInstall(_context)) {
        _set(busy: false, status: 'ListenJar needs “Install unknown apps” to update itself.');
        return;
      }
    }
    _set(status: 'Installing ${release.version}…');
    _installing = release;
    _listener = ApkInstaller$Listener.implement($ApkInstaller$Listener(onStatus: _installed, onStatus$async: true));
    final path = apk.path.toJString();
    ApkInstaller.install(_context, path, _listener);
    path.release();
  } on CancelledException {
    _set(busy: false, status: 'Update stopped.');
  } on Object catch (e) {
    _log.warning('update failed: $e');
    _set(busy: false, status: 'Couldn’t update: ${_why(e)}');
  } finally {
    _working = null;
  }
}

/// ApkInstaller's word on the install. Success ends this process. An APK it
/// refuses (not ListenJar, not newer, not from ListenJar's key) is deleted,
/// and automatic checks stop offering that build.
void _installed(JString? status, JString? message) {
  final s = status?.toDartString(releaseOriginal: true);
  final why = message?.toDartString(releaseOriginal: true);
  _log.warning('install: $s ${why ?? ''}');
  switch (s) {
    case 'refused':
      _set(busy: false, status: 'Couldn’t update: ${why ?? 'the download isn’t a ListenJar update.'}');
      if (_installing case final release?) _prefs['skipped'] = release.build;
      unawaited(_forget());
    case 'confirming':
      _set(busy: false, status: 'Android asks you to confirm the update.');
    case 'cancelled':
      _set(busy: false, status: 'Update cancelled. Check for updates to install it.');
    case 'installed':
      _set(busy: false, status: null);
    default:
      _set(busy: false, status: 'Couldn’t update: ${why ?? 'Android refused it.'}');
  }
}

/// The APK of [release] in the cache, downloaded now if it isn't already,
/// with the manifest's length and SHA-256.
Future<File> _downloaded(ApkRelease release, CancellationToken token) async {
  final apk = File('${_cache.path}/${release.asset}');
  if (await _verified(release)) return apk;
  await _forget();
  await _cache.create(recursive: true);
  final client = http.Client();
  final sink = apk.openWrite();
  try {
    _set(busy: true, status: 'Downloading ${release.version}…');
    final response = await client.send(http.Request('GET', Uri.parse('$_download/${release.tag}/${release.asset}'))).asCancellable(token);
    if (response.statusCode != 200) throw HttpException('GitHub answered ${response.statusCode}');
    var received = 0;
    var shown = -1;
    await for (final chunk in response.stream) {
      token.throwIfCancelled();
      sink.add(chunk);
      received += chunk.length;
      final percent = received * 100 ~/ release.length;
      if (percent != shown) {
        shown = percent;
        _set(status: 'Downloading ${release.version}… $percent%. Tap to stop.');
      }
    }
    await sink.close();
    if (!await _verified(release)) throw const FormatException('the download differs from the release');
    _prefs['downloaded'] = _json(release);
    await _save();
    return apk;
  } on Object {
    await sink.close().catchError((_) {});
    await _forget();
    rethrow;
  } finally {
    client.close();
  }
}

Future<bool> _verified(ApkRelease release) async {
  final apk = File('${_cache.path}/${release.asset}');
  if (!await apk.exists() || await apk.length() != release.length) return false;
  return (await sha256.bind(apk.openRead()).first).toString() == release.sha256;
}

/// Deletes downloaded APKs.
Future<void> _forget() async {
  if (_prefs.remove('downloaded') != null) await _save();
  if (await _cache.exists()) await _cache.delete(recursive: true);
}

/// Completes the next time the app comes back to the foreground.
Future<void> _resumed() {
  final back = Completer<void>();
  late final AppLifecycleListener listener;
  listener = AppLifecycleListener(onResume: () {
    listener.dispose();
    back.complete();
  });
  return back.future;
}

Future<void> _save() => _prefsFile.writeAsString(jsonEncode(_prefs));

ApkRelease? _release(Object? json) {
  if (json is! Map) return null;
  final (version, build, tag, asset, length, sha) =
    (json['version'], json['build'], json['tag'], json['asset'], json['length'], json['sha256']);
  if (version is! String || build is! int || tag is! String || asset is! String || length is! int || sha is! String) return null;
  if (json.containsKey('platform') && json['platform'] != 'android') return null;
  // Only a file name: it becomes a path in the cache.
  if (asset.contains('/') || asset.contains(r'\') || !asset.endsWith('.apk')) return null;
  return (version: version, build: build, tag: tag, asset: asset, length: length, sha256: sha);
}

Map<String, Object> _json(ApkRelease r) =>
  {'version': r.version, 'build': r.build, 'tag': r.tag, 'asset': r.asset, 'length': r.length, 'sha256': r.sha256};

String _why(Object e) => switch (e) {
  SocketException() || http.ClientException() => 'no connection to GitHub.',
  CancelledException() => 'it took too long.',
  JThrowable(:final message) => message,
  _ => '$e',
};

/// For `ext.listenjar.state`.
Map<String, Object?> apkUpdatesState() => {
  'build': _build,
  'offer': apkOffer.value?.version,
  'prefs': _prefs,
  'timer': _timer?.isActive,
};
