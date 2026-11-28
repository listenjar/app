// `moon run app:dev`: runs the app with `flutter run` and hot reloads it
// whenever a Dart file under packages/*/lib is saved, the way an IDE does.
// `flutter run` hot reloads on SIGUSR1 (`--pid-file` says where to send it).
// `r`, `R` and `q` still work in the terminal. `--print-dtd` prints the Dart
// Tooling Daemon's URI, which the Dart MCP server (`dart mcp-server`)
// connects to for hot reload, logs, errors and the widget tree.
//
// Native code (packages/youtubei/native) is not hot reloadable; restart.
//
// One debug app runs per device, from any checkout: this stands aside while
// another `app:dev` holds that device's lock in the temp directory (another
// session or checkout running the same device), or, on macOS, while a debug
// Listenjar.app is still running (from an IDE, or left behind by a
// `app:dev` that was killed outright). Standing aside exits 0, so
// `moonx dev` keeps the backend and web running instead of stopping them all.
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final app = Directory('${root.path}/packages/desktop');
  final device = args.firstOrNull ?? 'macos';

  // Held until this process exits, however it exits: the OS drops the lock.
  final lockFile = File('${Directory.systemTemp.path}/listenjar-desktop-dev-$device.lock');
  final lock = lockFile.openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
  } on FileSystemException {
    final holder = lockFile.readAsStringSync().trim();
    stderr.writeln(
      'app:dev is already running on $device (pid $holder): use that one, or stop it and run app:dev again.',
    );
    exit(0);
  }
  lock
    ..truncateSync(0)
    ..writeStringSync('$pid')
    ..flushSync();

  if (device == 'macos') {
    final running = Process.runSync('pgrep', ['-f', '/Debug/Listenjar.app/Contents/MacOS/Listenjar']);
    final apps = (running.stdout as String).trim().split('\n').where((line) => line.isNotEmpty);
    if (apps.isNotEmpty) {
      stderr.writeln(
        'A debug Listenjar is already running (pid ${apps.join(', ')}): quit it, then run app:dev again.',
      );
      exit(0);
    }
  }
  final pidFile = File('${Directory.systemTemp.path}/listenjar-desktop-${pid}.pid');
  final flutter = await Process.start(
    'flutter',
    ['run', '-d', device, '--pid-file', pidFile.path, '--print-dtd'],
    workingDirectory: app.path,
    mode: ProcessStartMode.inheritStdio,
  );

  Timer? pending;
  void reload(FileSystemEvent event) {
    if (!event.path.endsWith('.dart')) return;
    pending?.cancel();
    pending = Timer(const Duration(milliseconds: 150), () {
      final target = pidFile.existsSync() ? int.tryParse(pidFile.readAsStringSync().trim()) : null;
      if (target != null) Process.killPid(target, ProcessSignal.sigusr1);
    });
  }

  final watches = [
    for (final dir in ['packages/desktop/lib', 'packages/youtubei/lib'])
      Directory('${root.path}/$dir').watch(recursive: true).listen(reload),
  ];
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) => flutter.kill(signal));
  }

  final code = await flutter.exitCode;
  for (final watch in watches) {
    await watch.cancel();
  }
  if (pidFile.existsSync()) pidFile.deleteSync();
  exit(code);
}
