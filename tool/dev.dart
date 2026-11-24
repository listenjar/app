// `moon run desktop:dev`: runs the app with `flutter run` and hot reloads it
// whenever a Dart file under packages/*/lib is saved, the way an IDE does.
// `flutter run` hot reloads on SIGUSR1 (`--pid-file` says where to send it).
// `r`, `R` and `q` still work in the terminal. `--print-dtd` prints the Dart
// Tooling Daemon's URI, which the Dart MCP server (`dart mcp-server`)
// connects to for hot reload, logs, errors and the widget tree.
//
// Native code (packages/youtubei/native) is not hot reloadable; restart.
//
// Only one debug app runs at a time, from any checkout: this refuses to start
// while another `desktop:dev` holds the lock in the temp directory, or while a
// debug ListenJar.app is still running (from an IDE, or left behind by a
// `desktop:dev` that was killed outright).
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final app = Directory('${root.path}/packages/desktop');

  // Held until this process exits, however it exits: the OS drops the lock.
  final lockFile = File('${Directory.systemTemp.path}/listenjar-desktop-dev.lock');
  final lock = lockFile.openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
  } on FileSystemException {
    final holder = lockFile.readAsStringSync().trim();
    stderr.writeln('desktop:dev is already running (pid $holder): use that one, or stop it first.');
    exit(1);
  }
  lock
    ..truncateSync(0)
    ..writeStringSync('$pid')
    ..flushSync();

  final running = Process.runSync('pgrep', ['-f', '/Debug/ListenJar.app/Contents/MacOS/ListenJar']);
  final apps = (running.stdout as String).trim().split('\n').where((line) => line.isNotEmpty);
  if (apps.isNotEmpty) {
    stderr.writeln('A debug ListenJar is already running (pid ${apps.join(', ')}): quit it first.');
    exit(1);
  }
  final pidFile = File('${Directory.systemTemp.path}/listenjar-desktop-${pid}.pid');
  final flutter = await Process.start(
    'flutter',
    ['run', '-d', args.firstOrNull ?? 'macos', '--pid-file', pidFile.path, '--print-dtd'],
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
