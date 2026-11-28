import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'engine.dart';

/// What youtubei compiles beside QuickJS (engine.dart's engineSources).
const _bridgeSources = ['native/bridge.c', 'native/scripts.g.c'];

const _sources = [..._bridgeSources, ...engineSources];

/// The scripts native/scripts.g.c holds, as tool/scripts.mjs writes it
/// (`moon run app:scripts`); youtubejs.js is the bundle `moon run
/// app:bundle` builds from packages/youtubejs.
const _scripts = ['native/host.js', 'native/youtubejs.js', 'native/bindings.js'];

const _assetName = 'src/bindings.g.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final scripts = [for (final script in _scripts) input.packageRoot.resolve(script)];
    _checkGenerated(input.packageRoot.resolve('native/scripts.g.c'), scripts);
    output.dependencies.addAll(scripts);
    if (input.config.code.targetOS == OS.windows) {
      await _windows(input, output);
      return;
    }
    final os = input.config.code.targetOS;
    final engine = _prebuiltEngine(input);
    if (engine != null) {
      output.dependencies.addAll([engine.resolve('key'), engine.resolve(os.staticlibFileName(engineName))]);
    }
    await CBuilder.library(
      name: 'youtubei',
      assetName: _assetName,
      sources: engine == null ? _sources : _bridgeSources,
      includes: includes,
      defines: defines,
      flags: flags,
      // The engine before the system libraries it needs.
      libraries: [if (engine != null) engineName, ...systemLibraries(os)],
      libraryDirectories: [if (engine != null) engine.toFilePath()],
    ).run(input: input, output: output);
  });
}

/// native/engine/'s QuickJS for this build's target, when
/// `moon run app:engine-<platform>` built it from the sources as they are now.
Uri? _prebuiltEngine(BuildInput input) {
  final code = input.config.code;
  final apple = switch (code.targetOS) {
    OS.macOS => code.macOS.deploymentVersion,
    OS.iOS => code.iOS.deploymentVersion,
    _ => null,
  };
  if (apple != null && apple < engineAppleVersion) return null;
  final target = engineTarget(
    code.targetOS,
    code.targetArchitecture,
    sdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
  );
  final directory = input.packageRoot.resolve('native/engine/$target/');
  final key = File.fromUri(directory.resolve('key'));
  final library = File.fromUri(directory.resolve(code.targetOS.staticlibFileName(engineName)));
  if (!key.existsSync() || !library.existsSync()) return null;
  if (key.readAsStringSync().trim() != engineKey(input.packageRoot, target)) return null;
  return directory;
}

/// Fails unless [generated] holds the [scripts] as they are now: its first
/// lines are their SHA-256s.
void _checkGenerated(Uri generated, List<Uri> scripts) {
  const run = 'run `moon run app:scripts`';
  final file = File.fromUri(generated);
  if (!file.existsSync()) throw StateError('${file.path} is missing: $run');
  final lines = file.readAsLinesSync().take(scripts.length).toList();
  for (final (i, script) in scripts.indexed) {
    final source = File.fromUri(script);
    if (!source.existsSync()) throw StateError('${source.path} is missing: $run');
    final hash = sha256.convert(source.readAsBytesSync());
    if (i >= lines.length || !lines[i].startsWith('// sha256 $hash ')) {
      throw StateError('${file.path} is older than ${source.path}: $run');
    }
  }
}

/// MSYS2's MinGW-w64 C compiler for each Windows architecture, at its
/// default path, and the target triple prefix it must report.
final _mingw = {
  Architecture.x64: (cc: r'C:\msys64\ucrt64\bin\gcc.exe', triple: 'x86_64-'),
  Architecture.arm64: (cc: r'C:\msys64\clangarm64\bin\clang.exe', triple: 'aarch64-'),
};

Future<void> _windows(BuildInput input, BuildOutputBuilder output) async {
  final architecture = input.config.code.targetArchitecture;
  final toolchain = _mingw[architecture];
  if (toolchain == null) throw UnsupportedError('The Windows QuickJS build supports x64 and arm64, not $architecture');
  // Upstream QuickJS uses GNU C and winpthreads on Windows; MSVC cannot build
  // it. x64 uses UCRT64's GCC, arm64 CLANGARM64's Clang (MSYS2 has no arm64 GCC).
  final compiler = input.userDefines.path('mingw_cc')?.toFilePath() ?? toolchain.cc;
  final target = await Process.run(compiler, ['-dumpmachine']);
  final triple = target.stdout.toString().trim();
  if (target.exitCode != 0 || !triple.startsWith(toolchain.triple) || !RegExp('mingw|windows-gnu').hasMatch(triple)) {
    throw StateError('Configure hooks.user_defines.youtubei.mingw_cc with a MinGW-w64 C compiler for $architecture');
  }
  final library = input.outputDirectory.resolve('youtubei.dll');
  final sources = [for (final source in _sources) input.packageRoot.resolve(source)];
  final exports = input.packageRoot.resolve('native/windows.def');
  final result = await Process.run(compiler, [
    '-shared', '-O2', '-std=gnu11', '-fwrapv',
    for (final MapEntry(:key, :value) in defines.entries) value == null ? '-D$key' : '-D$key=$value',
    '-D__USE_MINGW_ANSI_STDIO',
    '-I${input.packageRoot.resolve('native/').toFilePath()}',
    '-I${input.packageRoot.resolve('native/quickjs/').toFilePath()}',
    for (final source in sources) source.toFilePath(),
    exports.toFilePath(), '-Wl,--exclude-all-symbols',
    '-o', library.toFilePath(),
    // Keep the compiler's runtime and winpthreads in this DLL; deployment
    // needs no MinGW DLLs.
    '-static', '-lm', '-lpthread',
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(compiler, const [], result.stderr.toString(), result.exitCode);
  }
  output.assets.code.add(CodeAsset(
    package: input.packageName,
    name: _assetName,
    file: library,
    linkMode: DynamicLoadingBundled(),
  ));
  output.dependencies.addAll([
    ...sources, exports, File(compiler).absolute.uri,
    input.packageRoot.resolve('native/bridge.h'),
    await for (final entry in Directory.fromUri(input.packageRoot.resolve('native/quickjs/')).list())
      if (entry is File && entry.path.endsWith('.h')) entry.uri,
  ]);
}
