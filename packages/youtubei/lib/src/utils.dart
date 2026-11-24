// YouTube.js's utils: InnertubeError (src/utils/Utils.ts) and UniversalCache
// (src/utils/Cache.ts) over the Node platform's file cache
// (src/platform/node.ts).
// ignore_for_file: non_constant_identifier_names
import 'dart:io';
import 'dart:typed_data';

/// An error YouTube.js threw. [name] is its class (`InnertubeError`,
/// `PlayerError`, `TypeError`…), [info] what it carried, serialized as
/// YouTube.js names it (the playability status of an unavailable video).
/// [cause] is the error of a failed fetch or cache operation behind it.
final class InnertubeError implements Exception {
  const InnertubeError(this.message, this.info, {this.name = 'InnertubeError', this.stack, this.cause});
  final String message;
  final Object? info;
  final String name;
  final String? stack;
  final Object? cause;

  @override
  String toString() => '$name: $message';
}

/// YouTube.js's cache: the session data and the parsed player, one file per
/// key. A persistent cache keeps them in [persistent_directory] (by default
/// `.cache/youtubei.js` in the working directory); otherwise in the system
/// temp directory.
final class UniversalCache {
  const UniversalCache(this.persistent, [this.persistent_directory]);
  final bool persistent;
  final String? persistent_directory;

  static String get temp_directory => '${Directory.systemTemp.path}/youtubei.js';
  static String get default_persistent_directory => '${Directory.current.path}/.cache/youtubei.js';

  String get cache_dir => persistent ? (persistent_directory ?? default_persistent_directory) : temp_directory;

  Future<Uint8List?> get(String key) => cacheGet(cache_dir, key);
  Future<void> set(String key, Uint8List value) => cacheSet(cache_dir, key, value);
  Future<void> remove(String key) => cacheRemove(cache_dir, key);
}

Future<File> _file(String directory, String key) async {
  final dir = Directory(directory);
  switch (await FileSystemEntity.type(directory)) {
    case FileSystemEntityType.notFound:
      await dir.create(recursive: true);
    case FileSystemEntityType.directory:
      break;
    default:
      throw StateError('An unexpected file was found in place of the cache directory');
  }
  return File('$directory/$key');
}

Future<Uint8List?> cacheGet(String directory, String key) async {
  final file = await _file(directory, key);
  return switch (await FileSystemEntity.type(file.path)) {
    FileSystemEntityType.file => await file.readAsBytes(),
    FileSystemEntityType.notFound => null,
    _ => throw StateError('An unexpected file was found in place of the cache key'),
  };
}

Future<void> cacheSet(String directory, String key, Uint8List value) async {
  await (await _file(directory, key)).writeAsBytes(value);
}

Future<void> cacheRemove(String directory, String key) async {
  final file = await _file(directory, key);
  if (await file.exists()) await file.delete();
}
