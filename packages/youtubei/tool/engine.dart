// Prebuilds QuickJS as a static library into native/engine/<target>/ for each
// target named, such as macos-arm64 or ios-arm64-simulator (`host` is this
// machine's), with the key the build hook checks before linking it instead of
// compiling QuickJS (hook/engine.dart). Run by `moon run app:engine-<platform>`,
// which caches native/engine/ on QuickJS's sources.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import '../hook/engine.dart';

Future<void> main(List<String> targets) async {
  if (targets.isEmpty) {
    stderr.writeln('usage: dart tool/engine.dart <os>-<arch>[-simulator]... | host');
    exit(64);
  }
  final root = Platform.script.resolve('../');
  final scratch = await Directory.systemTemp.createTemp('youtubei-engine-');
  try {
    // One compiler per target, side by side.
    await Future.wait([for (final target in targets) _build(root, scratch.uri, target)]);
  } finally {
    await scratch.delete(recursive: true);
  }
}

Future<void> _build(Uri root, Uri scratch, String name) async {
  final (os, architecture, sdk) = _parse(name);
  final target = engineTarget(os, architecture, sdk: sdk);
  final work = scratch.resolve('$target/');
  final input = (BuildInputBuilder()
        ..setupShared(
          packageName: 'youtubei',
          packageRoot: root,
          outputFile: work.resolve('output.json'),
          outputDirectoryShared: work.resolve('shared/'),
        )
        ..config.setupBuild(linkingEnabled: false)
        ..addExtension(CodeAssetExtension(
          targetOS: os,
          targetArchitecture: architecture,
          linkModePreference: LinkModePreference.static,
          macOS: os == OS.macOS ? MacOSCodeConfig(deploymentVersion: engineAppleVersion) : null,
          iOS: os == OS.iOS ? IOSCodeConfig(targetSdk: sdk!, deploymentVersion: engineAppleVersion) : null,
        )))
      .build();
  await CBuilder.library(
    name: engineName,
    assetName: null,
    sources: engineSources,
    includes: includes,
    defines: defines,
    flags: flags,
  ).run(input: input, output: BuildOutputBuilder());

  final library = os.staticlibFileName(engineName);
  final directory = Directory.fromUri(root.resolve('native/engine/$target/'));
  if (directory.existsSync()) await directory.delete(recursive: true);
  await directory.create(recursive: true);
  await File.fromUri(input.outputDirectory.resolve(library)).copy(directory.uri.resolve(library).toFilePath());
  // Last, so a half-written engine never matches.
  await File.fromUri(directory.uri.resolve('key')).writeAsString('${engineKey(root, target)}\n');
  stdout.writeln('native/engine/$target/$library');
}

(OS, Architecture, IOSSdk?) _parse(String name) {
  if (name == 'host') return (OS.current, Architecture.current, null);
  final parts = name.split('-');
  final os = OS.values.firstWhere((os) => os.name == parts.first, orElse: () => throw ArgumentError.value(name, 'target'));
  final architecture = Architecture.values.firstWhere(
    (architecture) => parts.length > 1 && architecture.name == parts[1],
    orElse: () => throw ArgumentError.value(name, 'target'),
  );
  final simulator = parts.length == 3 && parts[2] == 'simulator';
  if (parts.length > (simulator ? 3 : 2) || (simulator && os != OS.iOS)) throw ArgumentError.value(name, 'target');
  return (os, architecture, os == OS.iOS ? (simulator ? IOSSdk.iPhoneSimulator : IOSSdk.iPhoneOS) : null);
}
