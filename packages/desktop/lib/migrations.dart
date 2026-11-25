// Schema migrations: numbered SQL files in `assets/migrations/<name>/`,
// `0001_….sql` onwards. A database's `user_version` counts the files it ran;
// opening it runs the rest in order, each in its own transaction with the
// version it reaches, so a migration lands whole or not at all. Files are
// only ever added, never edited.
//
// A migration may put files, by path under the app's support directory, into
// `temp.trash`: they are deleted once it commits.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import 'links.dart';

/// Brings [db] up to the latest of the migrations in
/// `assets/migrations/[name]/`. [support] is where trashed paths live.
Future<void> migrate(Database db, String name, Directory support) async {
  final dir = 'assets/migrations/$name/';
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final files = manifest.listAssets().where((path) => path.startsWith(dir) && path.endsWith('.sql')).toList()..sort();
  for (final (i, path) in files.indexed) {
    final number = int.tryParse(path.substring(dir.length).split('_').first);
    if (number != i + 1) throw StateError('$path: migrations number 1, 2, 3… in order, this is ${i + 1}');
  }
  final from = db.select('pragma user_version').first.columnAt(0) as int;
  if (from >= files.length) return;

  db
    ..createFunction(
      functionName: 'canonical_source_url',
      function: (args) => switch (args.first) {
        final String url => canonicalSourceUrl(url),
        _ => null,
      },
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
    )
    ..execute('create temp table if not exists trash (path text not null)');
  for (var version = from + 1; version <= files.length; version++) {
    final sql = await rootBundle.loadString(files[version - 1], cache: false);
    db.execute('begin immediate');
    try {
      db
        ..execute(sql)
        ..execute('pragma user_version = $version')
        ..execute('commit');
    } catch (_) {
      db.execute('rollback');
      rethrow;
    }
    for (final row in db.select('delete from temp.trash returning path')) {
      try {
        File('${support.path}/${row['path']}').deleteSync();
      } on FileSystemException {
        // Gone already.
      }
    }
  }
  db.execute('drop table temp.trash');
}
