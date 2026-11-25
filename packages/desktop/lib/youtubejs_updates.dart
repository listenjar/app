// YouTube.js updates, as listenbox/client's sync-engine does them
// (crates/sync-engine/youtubejs.go). The app builds a bundle in, so YouTube
// works at once, and the fork's signed GitHub releases replace it without an
// app release: a push to listenbox/YouTube.js reaches every listener within
// seconds of its release workflow finishing.
//
// GitHub, the network and the bundle directory are all untrusted. Only source
// whose manifest the pinned release key signed, built for this app's bundle
// ABI ([Bundle.abi]) and newer than the bundle in use is ever evaluated.
//
// Releases are tags bundle-v<ABI>.<N> carrying youtubejs.json (the signed
// manifest) and youtubejs.js. Every ten seconds the app lists its ABI's tags
// with Git's own ref listing (`git ls-remote`), which, unlike GitHub's REST
// API, has no hourly limit for clients without a token; only a release number
// it hasn't seen yet costs more.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show Ed25519, KeyPairType, Signature, SimplePublicKey;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtubei/youtubei.dart' show Bundle;

final _log = Logger('youtube.bundle');

const _repository = 'listenbox/YouTube.js';
const _checkEvery = Duration(seconds: 10);
const _sourceAsset = 'youtubejs.js';
const _manifestAsset = 'youtubejs.json';
const _manifestFile = 'manifest.json';
const _stateFile = 'state.json';

// Every download is bounded before it is verified.
const _sourceLimit = 16 << 20;
const _manifestLimit = 64 << 10;
const _refsLimit = 1 << 20;

/// Verifies production releases; its private half stays offline.
final _releaseKey = SimplePublicKey(base64.decode('AR4hVDIhsP1dYU2UfIviBBrTqr7jmawFksR2bjRUTM4='), type: KeyPairType.ed25519);

/// Separates these signatures from any other use of the key.
const _signatureContext = 'listenbox youtubejs release v1\n';

/// Every release tag for this app's ABI starts so: the major version is the
/// host contract, and the release number only grows.
final _tagPrefix = 'bundle-v${Bundle.abi}.';

/// A signed release manifest's claims. [sequence] is its YouTube.js
/// commit's committer time, which the built-in bundle knows too: the app only
/// moves to a later one, so an old signed bundle can't be replayed under a
/// new tag.
final class ReleaseManifest {
  const ReleaseManifest._({required this.abi, required this.release, required this.sequence, required this.sha256, required this.size, required this.commit});

  final int abi;
  final int release;
  final int sequence;
  final String sha256;
  final int size;
  final String commit;

  String get tag => 'bundle-v$abi.$release';

  /// Verifies [signed], a youtubejs.json, before decoding what it claims.
  static Future<ReleaseManifest> open(Uint8List signed) async {
    final envelope = _strict(_decode(signed), const {'payload', 'signature'});
    final payload = _bytes(envelope['payload']);
    final signature = _bytes(envelope['signature']);
    final valid = signature.length == 64 && await Ed25519().verify(
      [...utf8.encode(_signatureContext), ...payload],
      signature: Signature(signature, publicKey: _releaseKey),
    );
    if (!valid) throw const _Rejected('YouTube.js release manifest signature is invalid');
    final claims = _strict(_decode(payload), const {'abi', 'release', 'sequence', 'sha256', 'size', 'commit'});
    final manifest = ReleaseManifest._(
      abi: _int(claims['abi']),
      release: _int(claims['release']),
      sequence: _int(claims['sequence']),
      sha256: _string(claims['sha256']),
      size: _int(claims['size']),
      commit: _string(claims['commit']),
    );
    if (manifest.abi <= 0 || manifest.release <= 0 || manifest.sequence <= 0) throw const _Rejected('manifest numbers must be positive');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(manifest.sha256)) throw const _Rejected('manifest digest must be lowercase SHA-256 hex');
    if (manifest.size <= 0 || manifest.size > _sourceLimit) throw _Rejected('manifest size ${manifest.size} is outside 1..$_sourceLimit');
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(manifest.commit)) throw const _Rejected('manifest commit must be a full lowercase SHA-1');
    return manifest;
  }

  /// Throws unless [source] is exactly the bundle this describes.
  void check(Uint8List source) {
    if (source.length != size) throw _Rejected('YouTube.js bundle is ${source.length} bytes, manifest says $size');
    if (sha256Of(source) != sha256) throw const _Rejected('YouTube.js bundle digest does not match its manifest');
  }
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// A verified release's bundle, to start YouTube.js with.
final class ReleasedBundle {
  const ReleasedBundle(this.manifest, this.source);
  final ReleaseManifest manifest;
  final Uint8List source;
}

/// A release that will never verify, so it isn't downloaded again.
final class _Rejected implements Exception {
  const _Rejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The app's YouTube.js bundles: [bundle] is the newest verified one, [watch]
/// looks for newer releases. Owns `youtubejs/` in the app's support
/// directory.
final class YouTubeJsUpdates {
  YouTubeJsUpdates();

  final _http = HttpClient()
    ..userAgent = 'ListenJar'
    ..connectionTimeout = const Duration(seconds: 15);
  Directory? _directory;

  /// The release in use, null for the built-in bundle; loaded on first use.
  ReleasedBundle? _current;
  var _loaded = false;

  /// Releases that failed to start, for the rest of this process.
  final _rejected = <int>{};
  Timer? _timer;
  var _checking = false;

  /// What the app runs now, for `ext.listenjar.state`.
  Map<String, Object?> get state => {
    'abi': Bundle.abi,
    'builtIn': Bundle.sequence,
    if (_current?.manifest case final m?) 'release': {'tag': m.tag, 'sequence': m.sequence, 'commit': m.commit},
  };

  Future<Directory> _dir() async => _directory ??= Directory('${(await getApplicationSupportDirectory()).path}/youtubejs');

  int get _sequence => _current?.manifest.sequence ?? Bundle.sequence;

  bool _adoptable(ReleaseManifest m) => m.abi == Bundle.abi && !_rejected.contains(m.sequence) && m.sequence > _sequence;

  /// The newest verified release, or null for the built-in bundle. The first
  /// call adopts the one an earlier run downloaded, verifying it again.
  Future<ReleasedBundle?> bundle() async {
    if (!_loaded) {
      _loaded = true;
      try {
        if (await _stored() case final stored? when _adoptable(stored.manifest)) _current = stored;
      } catch (e) {
        _log.warning('Ignoring the stored YouTube.js bundle', e);
      }
    }
    return _current;
  }

  Future<ReleasedBundle?> _stored() async {
    final dir = await _dir();
    final manifestFile = File('${dir.path}/$_manifestFile');
    if (!await manifestFile.exists()) return null;
    final manifest = await ReleaseManifest.open(await _readBounded(manifestFile, _manifestLimit));
    final source = await _readBounded(File('${dir.path}/${manifest.sha256}.js'), _sourceLimit);
    manifest.check(source);
    return ReleasedBundle(manifest, source);
  }

  /// Drops [failed], which YouTube.js couldn't start from, for the rest of
  /// this process and returns to the built-in bundle; later runs start from
  /// it too, and the release isn't downloaded again.
  Future<void> reject(ReleasedBundle failed, Object error) async {
    _log.warning('YouTube.js ${failed.manifest.tag} failed to start; using the built-in bundle', error);
    _rejected.add(failed.manifest.sequence);
    if (!identical(_current, failed)) return;
    _current = null;
    try {
      await File('${(await _dir()).path}/$_manifestFile').delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Checks for a newer release now and every ten seconds, until [close];
  /// [adopted] runs once one verifies.
  void watch(FutureOr<void> Function(ReleasedBundle) adopted) {
    _timer?.cancel();
    Future<void> tick() async {
      if (_checking) return;
      _checking = true;
      try {
        if (await check() case final next?) await adopted(next);
      } catch (e) {
        _log.fine('YouTube.js release check failed', e);
      } finally {
        _checking = false;
      }
    }

    unawaited(tick());
    _timer = Timer.periodic(_checkEvery, (_) => unawaited(tick()));
  }

  void close() {
    _timer?.cancel();
    _http.close(force: true);
  }

  /// Adopts a newer signed release, if there is one, and returns it.
  Future<ReleasedBundle?> check() async {
    await bundle(); // The stored release, to compare against.
    final latest = await _latestRelease();
    if (latest == 0) return null;
    final dir = await _dir();
    final stateFile = File('${dir.path}/$_stateFile');
    final seen = await _seenRelease(stateFile);
    if (latest <= seen) return null;
    ReleasedBundle? next;
    try {
      next = await _download(latest);
    } on _Rejected catch (e) {
      _log.warning('Rejecting YouTube.js $_tagPrefix$latest', e);
    }
    // Transient failures throw past this, so the next check tries again.
    await _writeAtomically(stateFile, utf8.encode(jsonEncode({'release': latest})));
    return next;
  }

  Future<int> _seenRelease(File file) async {
    try {
      return switch (jsonDecode(await file.readAsString())) {
        {'release': final int release} => release,
        _ => 0,
      };
    } on Object {
      return 0;
    }
  }

  /// The highest release number for this app's ABI, 0 when there is none:
  /// Git protocol v2's ls-refs, as `git ls-remote` asks it.
  Future<int> _latestRelease() async {
    final request = await _http.postUrl(Uri.parse('https://github.com/$_repository.git/git-upload-pack'));
    request.headers
      ..set('Git-Protocol', 'version=2')
      ..set(HttpHeaders.contentTypeHeader, 'application/x-git-upload-pack-request')
      ..set(HttpHeaders.acceptHeader, 'application/x-git-upload-pack-result');
    request.add([
      ..._pkt('command=ls-refs\n'),
      ..._pkt('object-format=sha1\n'),
      ...ascii.encode('0001'),
      ..._pkt('ref-prefix refs/tags/$_tagPrefix\n'),
      ...ascii.encode('0000'),
    ]);
    final response = await request.close();
    final body = await _readResponse(response, _refsLimit);
    if (response.statusCode != HttpStatus.ok) throw HttpException('list YouTube.js releases: HTTP ${response.statusCode}');
    var latest = 0;
    for (final line in _pktLines(body)) {
      if (line.startsWith('ERR ')) throw HttpException('list YouTube.js releases: ${line.substring(4).trim()}');
      final ref = line.trim().split(' ').elementAtOrNull(1) ?? '';
      if (_releaseOf(ref.replaceFirst('refs/tags/', '')) case final release? when release > latest) latest = release;
    }
    return latest;
  }

  /// Adopts release [release] when its signed manifest verifies and its
  /// bundle is newer than the one in use; only then is the bundle fetched.
  Future<ReleasedBundle?> _download(int release) async {
    final tag = '$_tagPrefix$release';
    final signed = await _asset(tag, _manifestAsset, _manifestLimit);
    final manifest = await ReleaseManifest.open(signed);
    if (manifest.tag != tag) throw _Rejected('release $tag carries the manifest of ${manifest.tag}');
    if (!_adoptable(manifest)) return null; // The bundle in use is this commit or a later one.
    final source = await _asset(tag, _sourceAsset, manifest.size);
    manifest.check(source);
    await _store(manifest, signed, source);
    if (!_adoptable(manifest)) return null;
    final next = ReleasedBundle(manifest, source);
    _current = next;
    _log.info('Adopted YouTube.js $tag (${manifest.commit.substring(0, 7)})');
    return next;
  }

  Future<Uint8List> _asset(String tag, String name, int limit) async {
    final request = await _http.getUrl(Uri.parse('https://github.com/$_repository/releases/download/$tag/$name'));
    final response = await request.close();
    // An oversized body comes back cut short, so verification rejects it.
    final body = await _readResponse(response, limit + 1, truncate: true);
    if (response.statusCode != HttpStatus.ok) throw HttpException('download $tag/$name: HTTP ${response.statusCode}');
    return body;
  }

  /// Writes the source under its digest before the manifest that names it,
  /// so a crash leaves either the old pair or the new one.
  Future<void> _store(ReleaseManifest manifest, Uint8List signed, Uint8List source) async {
    final dir = await (await _dir()).create(recursive: true);
    await _writeAtomically(File('${dir.path}/${manifest.sha256}.js'), source);
    await _writeAtomically(File('${dir.path}/$_manifestFile'), signed);
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.js') && !entry.path.endsWith('/${manifest.sha256}.js')) {
        await entry.delete().catchError((_) => entry);
      }
    }
  }
}

/// The release number in [tag] for this app's ABI, or null for any other.
int? _releaseOf(String tag) {
  if (!tag.startsWith(_tagPrefix)) return null;
  final digits = tag.substring(_tagPrefix.length);
  if (!RegExp(r'^[1-9][0-9]{0,17}$').hasMatch(digits)) return null;
  return int.parse(digits);
}

List<int> _pkt(String line) => ascii.encode('${(line.length + 4).toRadixString(16).padLeft(4, '0')}$line');

/// The data lines of a pkt-line stream, up to its flush packet.
Iterable<String> _pktLines(Uint8List body) sync* {
  var at = 0;
  while (at + 4 <= body.length) {
    final length = int.tryParse(ascii.decode(body.sublist(at, at + 4), allowInvalid: true), radix: 16);
    if (length == null) throw const FormatException('malformed pkt-line');
    if (length == 0) return;
    if (length < 4) {
      at += 4;
      continue;
    }
    if (at + length > body.length) throw const FormatException('truncated pkt-line');
    yield utf8.decode(body.sublist(at + 4, at + length), allowMalformed: true);
    at += length;
  }
}

Future<Uint8List> _readResponse(HttpClientResponse response, int limit, {bool truncate = false}) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in response) {
    out.add(chunk);
    if (out.length > limit) {
      if (truncate) return Uint8List.sublistView(out.takeBytes(), 0, limit);
      throw HttpException('response over $limit bytes');
    }
  }
  return out.takeBytes();
}

Future<Uint8List> _readBounded(File file, int limit) async {
  if (await file.length() > limit) throw FileSystemException('over $limit bytes', file.path);
  return file.readAsBytes();
}

Future<void> _writeAtomically(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  await temporary.rename(file.path);
}

Object? _decode(List<int> bytes) {
  try {
    return jsonDecode(utf8.decode(bytes));
  } on FormatException catch (e) {
    throw _Rejected('decode YouTube.js release manifest: ${e.message}');
  }
}

/// [value] as an object with exactly [keys].
Map<String, Object?> _strict(Object? value, Set<String> keys) {
  if (value is! Map<String, Object?> || value.length != keys.length || !value.keys.every(keys.contains)) {
    throw _Rejected('YouTube.js release manifest must have exactly ${keys.join(', ')}');
  }
  return value;
}

Uint8List _bytes(Object? value) {
  if (value is! String) throw const _Rejected('expected base64');
  try {
    return base64.decode(value);
  } on FormatException {
    throw const _Rejected('expected base64');
  }
}

int _int(Object? value) => value is int ? value : throw const _Rejected('expected an integer');

String _string(Object? value) => value is String ? value : throw const _Rejected('expected a string');
