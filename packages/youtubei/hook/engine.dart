// QuickJS, the engine youtubei embeds, compiled apart from the bridge and the
// scripts. It changes only with the vendored native/quickjs, while the bundle
// in native/scripts.g.c changes often, so `moon run app:engine-<platform>`
// (tool/engine.dart) prebuilds it as a static library into
// native/engine/<target>/ and moon caches that, shared by every worktree.
// The build hook (build.dart) links a prebuilt engine whose key matches, and
// compiles QuickJS itself when there is none.
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';

const engineSources = [
  'native/quickjs/quickjs.c',
  'native/quickjs/libregexp.c',
  'native/quickjs/libunicode.c',
  'native/quickjs/cutils.c',
  'native/quickjs/dtoa.c',
];

const includes = ['native', 'native/quickjs'];
const defines = {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"2026-06-04"'};
const flags = ['-std=gnu11', '-fwrapv'];

/// The system libraries QuickJS needs on [os], after the engine itself.
List<String> systemLibraries(OS os) => switch (os) {
  OS.linux => ['m', 'pthread'],
  OS.android => ['m'],
  _ => const [],
};

/// The lowest macOS and iOS version the prebuilt engines run on. Flutter asks
/// the hook for 13 or later; an engine for an older one compiles in the hook.
final engineAppleVersion = AppleVersion(13);

/// The name of the static library in each `native/engine/<target>/`.
const engineName = 'quickjs';

/// native/engine/'s directory for a target, such as macos-arm64 or
/// ios-arm64-simulator.
String engineTarget(OS os, Architecture architecture, {IOSSdk? sdk}) =>
    [os.name, architecture.name, if (sdk == IOSSdk.iPhoneSimulator) 'simulator'].join('-');

/// What an engine for [target] compiles from: QuickJS's sources and headers,
/// and how this file compiles them. A prebuilt engine's `key` file holds it.
String engineKey(Uri packageRoot, String target) {
  final quickjs = Directory.fromUri(packageRoot.resolve('native/quickjs/'));
  final files = [
    for (final entry in quickjs.listSync())
      if (entry is File && (entry.path.endsWith('.c') || entry.path.endsWith('.h'))) entry,
  ]..sort((a, b) => a.path.compareTo(b.path));
  final recipe = jsonEncode({
    'target': target,
    'apple': '$engineAppleVersion',
    'defines': defines,
    'flags': flags,
    'files': {for (final file in files) file.uri.pathSegments.last: sha256.convert(file.readAsBytesSync()).toString()},
  });
  return sha256.convert(utf8.encode(recipe)).toString();
}
