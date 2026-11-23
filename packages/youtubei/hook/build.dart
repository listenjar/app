import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _sources = [
  'native/bridge.c',
  'native/quickjs/quickjs.c',
  'native/quickjs/libregexp.c',
  'native/quickjs/libunicode.c',
  'native/quickjs/cutils.c',
  'native/quickjs/dtoa.c',
  'native/scripts.c',
];

/// The scripts native/scripts.c embeds; youtubejs.js is the bundle
/// `moon run desktop:bundle` builds from packages/youtubejs.
const _scripts = ['native/host.js', 'native/youtubejs.js', 'native/bindings.js'];

const _assetName = 'src/bindings.g.dart';
const _defines = {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"2026-06-04"'};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final scripts = [for (final script in _scripts) input.packageRoot.resolve(script)];
    for (final script in scripts) {
      if (!File.fromUri(script).existsSync()) {
        throw StateError('${script.toFilePath()} is missing: run `moon run desktop:bundle`');
      }
    }
    output.dependencies.addAll(scripts);
    if (input.config.code.targetOS == OS.windows) {
      await _windows(input, output);
      return;
    }
    await CBuilder.library(
      name: 'youtubei',
      assetName: _assetName,
      sources: _sources,
      includes: ['native', 'native/quickjs'],
      defines: _defines,
      flags: ['-std=gnu11', '-fwrapv', '-Wno-c23-extensions'],
      libraries: switch (input.config.code.targetOS) {
        OS.linux => ['m', 'pthread'],
        OS.android => ['m'],
        _ => const [],
      },
    ).run(input: input, output: output);
  });
}

Future<void> _windows(BuildInput input, BuildOutputBuilder output) async {
  if (input.config.code.targetArchitecture != Architecture.x64) {
    throw UnsupportedError('The Windows QuickJS build currently supports x64');
  }
  // Upstream QuickJS uses GNU C and winpthreads on Windows; MSVC cannot build it.
  final compiler = input.userDefines.path('mingw_cc')?.toFilePath() ?? r'C:\msys64\ucrt64\bin\gcc.exe';
  final target = await Process.run(compiler, ['-dumpmachine']);
  if (target.exitCode != 0 ||
      !target.stdout.toString().trim().startsWith('x86_64-') ||
      !target.stdout.toString().contains('mingw')) {
    throw StateError('Configure hooks.user_defines.youtubei.mingw_cc with an x64 MinGW-w64 GCC');
  }
  final library = input.outputDirectory.resolve('youtubei.dll');
  final sources = [for (final source in _sources) input.packageRoot.resolve(source)];
  final exports = input.packageRoot.resolve('native/windows.def');
  final result = await Process.run(compiler, [
    '-shared', '-O2', '-std=gnu11', '-fwrapv',
    for (final MapEntry(:key, :value) in _defines.entries) value == null ? '-D$key' : '-D$key=$value',
    '-D__USE_MINGW_ANSI_STDIO',
    '-I${input.packageRoot.resolve('native/').toFilePath()}',
    '-I${input.packageRoot.resolve('native/quickjs/').toFilePath()}',
    for (final source in sources) source.toFilePath(),
    exports.toFilePath(), '-Wl,--exclude-all-symbols',
    '-o', library.toFilePath(),
    // Keep GCC and winpthreads in this DLL; deployment needs no MinGW DLLs.
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
