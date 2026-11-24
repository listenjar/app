// Versions and the Linux and Android packages of a release:
//
//   dart tool/release.dart prepare         reserve the next version tag
//   dart tool/release.dart build PLATFORM  build and package linux or android
//
// .github/workflows/version.yaml runs `prepare` on every push to master and
// then dispatches release.yaml on the tag, which builds every platform into
// build/release/: macOS and Windows with
// tool/package-macos.sh and tool/package-windows.ps1, Linux and Android with
// `build` here (ListenJar-<version>-linux-x64.tar.gz, -android-<abi>.apk), and
// tool/release.ts signs the updates, writes the appcasts and publishes.
//
// Android: `build android` refuses an APK not signed with the release key
// whose certificate passkeys.ts lists (android/app/build.gradle.kts signs
// with it): Android updates an app only with the key it was installed with.
//
// Versions: packages/desktop/pubspec.yaml holds the base, X.Y.Z+BUILD. Each
// master push gets the next patch above the newest vX.Y.Z tag (or the base, if
// it is newer) and the next build number (Android's versionCode and the
// updaters' build), committed on top of the pushed commit as "Release vX.Y.Z"
// with a Source-commit trailer. Only the tag points at that commit; master
// never moves. Raise the base in pubspec.yaml to start a new minor or major.
import 'dart:io';
import 'dart:math';

const _repository = 'listenjar/desktop';
const _manifest = 'packages/desktop/pubspec.yaml';
const _platforms = ['linux', 'android'];

/// Android's release APKs, one per ABI (`flutter build apk --split-per-abi`),
/// as tool/release.ts and lib/apk_updates.dart name them.
const _abis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

final _root = File.fromUri(Platform.script).absolute.parent.parent;
final _app = Directory('${_root.path}/packages/desktop');
final _out = Directory('${_root.path}/build/release');

Future<void> main(List<String> args) async {
  switch (args) {
    case ['prepare']:
      _prepare();
    case ['build', final platform] when _platforms.contains(platform):
      await _build(platform);
    default:
      stderr.writeln('usage: dart tool/release.dart prepare | build ${_platforms.join('|')}');
      exit(64);
  }
}

// Versions -------------------------------------------------------------------

typedef Version = ({int major, int minor, int patch, int build});

final _versionLine = RegExp(r'^version: (\S+)[ \t]*$', multiLine: true);
final _versionValue = RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)$');
final _tagValue = RegExp(r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$');

Version _version(String manifest) {
  final lines = _versionLine.allMatches(manifest).toList();
  final match = lines.length == 1 ? _versionValue.firstMatch(lines.single.group(1)!) : null;
  if (match == null) throw StateError('$_manifest needs one `version: X.Y.Z+BUILD`');
  final parts = [for (var i = 1; i <= 4; i++) int.parse(match.group(i)!)];
  return (major: parts[0], minor: parts[1], patch: parts[2], build: parts[3]);
}

String _semver(Version v) => '${v.major}.${v.minor}.${v.patch}';
String _full(Version v) => '${_semver(v)}+${v.build}';

int _compare(Version a, Version b) {
  for (final c in [a.major.compareTo(b.major), a.minor.compareTo(b.minor), a.patch.compareTo(b.patch)]) {
    if (c != 0) return c;
  }
  return 0;
}

Version _next(Version base, Version? latest) {
  if (latest == null) return base;
  final build = max(base.build, latest.build + 1);
  if (_compare(base, latest) > 0) return (major: base.major, minor: base.minor, patch: base.patch, build: build);
  return (major: latest.major, minor: latest.minor, patch: latest.patch + 1, build: build);
}

/// The version in the checked-out pubspec.
Version get _current => _version(File('${_root.path}/$_manifest').readAsStringSync());

// prepare --------------------------------------------------------------------

void _prepare() {
  final env = Platform.environment;
  final source = env['GITHUB_SHA'];
  final output = env['GITHUB_OUTPUT'];
  if (env['GITHUB_ACTIONS'] != 'true' ||
      env['GITHUB_REPOSITORY'] != _repository ||
      env['GITHUB_REF'] != 'refs/heads/master' ||
      source == null ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(source) ||
      output == null) {
    throw StateError('prepare runs in GitHub Actions on a push to master of $_repository');
  }
  if (_git(['rev-parse', 'HEAD']).trim() != source) throw StateError('HEAD is not $source');
  if (_git(['status', '--porcelain', '--untracked-files=normal']).isNotEmpty) {
    throw StateError('prepare needs a clean checkout');
  }

  _git(['fetch', '--no-recurse-submodules', '--tags', 'origin', 'master']);
  if (_git(['rev-parse', 'origin/master']).trim() != source) {
    stdout.writeln('Skipping $source: master has moved on.');
    return;
  }

  final manifest = File('${_root.path}/$_manifest').readAsStringSync();
  Version? latest;
  String? existing;
  for (final tag in _git(['tag', '--list', 'v*']).split('\n').where(_tagValue.hasMatch)) {
    final commit = _git(['rev-parse', '$tag^{commit}']).trim();
    final message = _git(['show', '-s', '--format=%B', commit]);
    final trailer = RegExp(r'^Source-commit: ([0-9a-f]{40})$', multiLine: true).firstMatch(message)?.group(1);
    final parents = _git(['rev-list', '--parents', '-n', '1', commit]).trim().split(' ');
    if (trailer == null || parents.length != 2 || parents[1] != trailer) {
      throw StateError('$tag is not a release commit (Release vX.Y.Z on top of its Source-commit)');
    }
    final tagged = _version(_git(['show', '$tag:$_manifest']));
    if ('v${_semver(tagged)}' != tag) throw StateError('$tag does not match its pubspec version');
    if (trailer == source) existing = tag;
    if (latest == null || _compare(tagged, latest) > 0) latest = tagged;
  }

  if (existing != null) {
    // A rerun: build the tag this commit already has.
    _emit(output, existing, _version(_git(['show', '$existing:$_manifest'])));
    stdout.writeln('Reusing $existing for $source.');
    return;
  }

  final next = _next(_version(manifest), latest);
  final tag = 'v${_semver(next)}';
  File('${_root.path}/$_manifest')
      .writeAsStringSync(manifest.replaceFirst(_versionLine, 'version: ${_full(next)}'));
  final date = _git(['show', '-s', '--format=%cI', source]).trim();
  _git([
    '-c', 'user.name=github-actions[bot]',
    '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
    '-c', 'commit.gpgsign=false',
    // Empty for the first release, which keeps the base version.
    'commit', '--quiet', '--allow-empty', '--only', _manifest,
    '-m', 'Release $tag', '-m', 'Source-commit: $source',
  ], environment: {'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date});
  _git(['tag', tag]);
  _git(['push', 'origin', 'refs/tags/$tag']);
  _emit(output, tag, next);
  stdout.writeln('Reserved $tag (${_full(next)}) for $source.');
}

void _emit(String output, String tag, Version version) => File(output)
    .writeAsStringSync('tag=$tag\nversion=${_semver(version)}\n', mode: FileMode.append);

// build ----------------------------------------------------------------------

Future<void> _build(String platform) async {
  final version = _semver(_current);
  final name = 'ListenJar-$version-$platform';
  final target = switch (platform) {
    // One APK per ABI, each with the build number as its versionCode
    // (android/gradle.properties).
    'android' => ['apk', '--split-per-abi'],
    _ => [platform],
  };
  await _stream('flutter', ['build', ...target, '--release'], workingDirectory: _app.path);
  _out.createSync(recursive: true);

  switch (platform) {
    case 'linux':
      final bundle = '${_app.path}/build/linux/x64/release/bundle';
      final staged = Directory('${_out.path}/.$name')..createSync();
      try {
        await _stream('cp', ['-R', bundle, '${staged.path}/ListenJar']);
        await _stream('tar', ['-C', staged.path, '-czf', '${_out.path}/$name-x64.tar.gz', 'ListenJar']);
      } finally {
        staged.deleteSync(recursive: true);
      }
    case 'android':
      for (final abi in _abis) {
        final apk = '${_app.path}/build/app/outputs/flutter-apk/app-$abi-release.apk';
        _checkSigner(apk);
        File(apk).copySync('${_out.path}/$name-$abi.apk');
      }
  }
  for (final file in _out.listSync().whereType<File>()) {
    stdout.writeln('Packaged ${file.path} (${file.lengthSync()} bytes)');
  }
}

// Android signing ------------------------------------------------------------

/// The release certificate's SHA-256 as lowercase hex, from passkeys.ts,
/// which also lets the app's passkeys through.
String _releaseCertificate() {
  final passkeys = File('${_root.path}/passkeys.ts').readAsStringSync();
  final fingerprints = RegExp(r'"((?:[0-9A-F]{2}:){31}[0-9A-F]{2})"').allMatches(passkeys).toList();
  if (fingerprints.length != 1) throw StateError('passkeys.ts needs exactly one Android certificate SHA-256');
  return fingerprints.single.group(1)!.replaceAll(':', '').toLowerCase();
}

/// Fails unless [apk] verifies and its only signer is the release certificate.
void _checkSigner(String apk) {
  final certificate = _releaseCertificate();
  final sdk = Platform.environment['ANDROID_HOME'] ?? Platform.environment['ANDROID_SDK_ROOT'];
  final tools = sdk == null ? null : Directory('$sdk/build-tools');
  final versions = tools != null && tools.existsSync() ? tools.listSync().whereType<Directory>().toList() : <Directory>[];
  if (versions.isEmpty) throw StateError('No Android build-tools (apksigner) under ANDROID_HOME');
  String name(Directory d) => d.path.split(Platform.pathSeparator).last;
  versions.sort((a, b) => _compareVersions(name(a), name(b)));
  final apksigner = '${versions.last.path}/apksigner';
  final output = _run(apksigner, ['verify', '--print-certs', apk]);
  final signers = RegExp(r'certificate SHA-256 digest: ([0-9a-f]{64})').allMatches(output).map((m) => m.group(1)).toSet();
  if (signers.length != 1 || signers.single != certificate) {
    throw StateError('$apk is signed by ${signers.join(', ')}, not the release certificate $certificate');
  }
  stdout.writeln('Signed with the release certificate $certificate');
}

int _compareVersions(String a, String b) {
  final x = a.split(RegExp(r'[.-]')).map((p) => int.tryParse(p) ?? -1).toList();
  final y = b.split(RegExp(r'[.-]')).map((p) => int.tryParse(p) ?? -1).toList();
  for (var i = 0; i < max(x.length, y.length); i++) {
    final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (c != 0) return c;
  }
  return 0;
}

// processes ------------------------------------------------------------------

String _git(List<String> args, {Map<String, String>? environment}) => _run('git', args, environment: environment);

String _run(String command, List<String> args, {Map<String, String>? environment}) {
  final result = Process.runSync(command, args,
      workingDirectory: _root.path, environment: environment, runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    throw ProcessException(command, args, '${result.stderr}'.trim(), result.exitCode);
  }
  return result.stdout as String;
}

Future<void> _stream(String command, List<String> args, {String? workingDirectory}) async {
  final process = await Process.start(command, args,
      workingDirectory: workingDirectory ?? _root.path,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows);
  final code = await process.exitCode;
  if (code != 0) throw ProcessException(command, args, 'exit $code', code);
}
