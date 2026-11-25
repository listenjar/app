// The YouTube.js engine, ported from the Go youtubei crate's engine.go.
//
// One QuickJS runtime lives in its own isolate, which owns every JavaScript
// value and runs YouTube.js's promise jobs and timers. Dart calls JavaScript;
// JavaScript never calls Dart. After each call in, the engine takes the
// outbox (host.js): finished calls, fetches, digests, cache reads and writes,
// timers and log lines, and answers them by calling in again. The owner
// isolate keeps the transport: YouTube.js's fetch comes back to the caller's
// Fetch, so cookies, HTTP and policy stay outside this package. Calls may
// overlap while they await I/O; closing drains accepted calls first.
//
// Cancellation is cooperative through CancellationToken: a cancelled call
// completes with the token's exception at once, its in-flight fetches are
// cancelled, and JavaScript running on its behalf is interrupted.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'package:meta/meta.dart';

import 'bindings.g.dart';
import 'fetch.dart';
import 'utils.dart';

/// Where YouTube.js's log lines go: [level] is `error`, `warning`, `info` or
/// `debug`.
typedef YouTubeiLog = void Function(String level, String message);

/// The YouTube.js bundles a runtime can evaluate: the one built in, or the
/// source of a signed release of the fork (its `youtubejs.js`), which the
/// caller fetches and verifies.
abstract final class Bundle {
  /// The contract between host.js and bindings.js and the bundle: a release
  /// for another ABI won't run here. The fork's `.github/bundle/abi`.
  static const abi = 1;

  /// The built-in bundle's sequence: its YouTube.js commit's committer time,
  /// as release manifests carry it. A release with a later one is newer.
  static int get sequence => yt_bundle_sequence();
}

/// A bundle that failed to evaluate.
final class BundleError extends StateError {
  BundleError(super.message);
}

const _memoryLimit = 768 << 20;
// Dart runs isolates on threads with small native stacks; stay well inside.
const _stackLimit = 512 << 10;

/// A running engine, behind one Innertube: call into it with [callYouTubei],
/// stop it with [closeYouTubei].
@internal
final class YouTubei {
  YouTubei._(this._fetch, this._log, this._interrupt, this._events);

  final Fetch _fetch;
  final YouTubeiLog? _log;
  final Pointer<YtInterrupt> _interrupt;
  final ReceivePort _events;
  late final SendPort _commands;
  final _exited = Completer<void>();
  final _calls = <int, CancellableCompleter<Object?>>{};
  final _asks = <int, ({int call, CancellationToken token})>{};
  final _hostErrors = <int, ({int call, Object error})>{};
  var _nextCall = 0;
  var _nextHostError = 0;
  var _closing = false;
  final _released = <int>[];
}

/// Releases a live YouTube.js object's handle once [owner], the Dart object
/// standing for it, is collected.
@internal
void retainHandle(YouTubei yt, Object owner, int handle) => _handles.attach(owner, (yt, handle));

final _handles = Finalizer<(YouTubei, int)>((h) {
  final (yt, handle) = h;
  if (yt._closing) return;
  yt._released.add(handle);
  if (yt._released.length > 1) return;
  scheduleMicrotask(() {
    final handles = [...yt._released];
    yt._released.clear();
    if (yt._closing) return;
    unawaited(callYouTubei(yt, '__bridge.release', handles).then<void>((_) {}, onError: (_) {}));
  });
});

/// Starts an engine: a new isolate evaluates [bundle], a YouTube.js
/// bundle's source, or the built-in one. [log] receives YouTube.js's log
/// lines.
@internal
Future<YouTubei> startYouTubei(Fetch fetch, {Uint8List? bundle, CancellationToken? token, YouTubeiLog? log}) async {
  token?.throwIfCancelled();
  final interrupt = yt_interrupt_new();
  if (interrupt == nullptr) throw StateError('allocate the QuickJS interrupt');
  final yt = YouTubei._(fetch, log, interrupt, ReceivePort('youtubei'));
  final ready = CancellableCompleter<void>(token, onCancel: () => yt_interrupt_close(interrupt));
  yt._events.listen((message) => _onEvent(yt, message, ready));
  try {
    final source = bundle == null ? null : TransferableTypedData.fromList([bundle]);
    await Isolate.spawn(_engineMain, (yt._events.sendPort, interrupt.address, source), debugName: 'youtubei');
  } catch (_) {
    _dispose(yt);
    rethrow;
  }
  await ready.future;
  return yt;
}

/// Stops accepting calls, waits for accepted ones to finish, then frees the
/// runtime. Cancel the calls' tokens to stop them sooner.
@internal
Future<void> closeYouTubei(YouTubei yt) async {
  if (!yt._closing) {
    yt._closing = true;
    yt._commands.send(const _Close());
  }
  await yt._exited.future;
}

/// Calls `expression(args)` in YouTube.js and returns its JSON value.
@internal
Future<Object?> callYouTubei(YouTubei yt, String expression, Object? args, {CancellationToken? token}) async {
  if (yt._closing) throw StateError('YouTube runtime closed');
  token?.throwIfCancelled();
  final id = ++yt._nextCall;
  final completer = CancellableCompleter<Object?>(token, onCancel: () => _cancelCall(yt, id));
  yt._calls[id] = completer;
  yt._commands.send(_Invoke(id, expression, jsonEncode(args)));
  return completer.future;
}

void _cancelCall(YouTubei yt, int id) {
  if (yt._calls.remove(id) == null) return;
  yt_interrupt_cancel(yt._interrupt, id);
  yt._commands.send(_Cancel(id));
  for (final ask in yt._asks.values) {
    if (ask.call == id) ask.token.cancel();
  }
  yt._hostErrors.removeWhere((_, e) => e.call == id);
}

void _dispose(YouTubei yt) {
  yt._events.close();
  yt_interrupt_free(yt._interrupt);
}

void _onEvent(YouTubei yt, Object? message, CancellableCompleter<void> ready) {
  switch (message) {
    case _Ready(:final commands):
      yt._commands = commands;
      // Started after the caller gave up: stop it again.
      if (ready.isCancelled) {
        yt._closing = true;
        commands.send(const _Close());
      }
      ready.complete();
    case _StartFailed(:final message):
      ready.completeError(StateError('initialize embedded YouTube.js: $message'));
    case _LoadFailed(:final message):
      ready.completeError(BundleError('evaluate YouTube.js: $message'));
    case _Ask(:final id, :final call, :final kind, :final fields):
      unawaited(_runAsk(yt, id, call, kind, fields));
    case _Log(:final level, :final message):
      yt._log?.call(level, message);
    case _Done(:final id, :final result):
      _complete(yt, id, result);
    case _Fault(:final message):
      for (final id in yt._calls.keys.toList()) {
        _complete(yt, id, {'error': {'message': message}});
      }
    case _Exited():
      for (final id in yt._calls.keys.toList()) {
        _complete(yt, id, {'error': {'message': 'YouTube runtime stopped before completing the operation'}});
      }
      _dispose(yt);
      yt._exited.complete();
  }
}

void _complete(YouTubei yt, int id, Map<String, Object?> result) {
  final completer = yt._calls.remove(id);
  if (completer == null) return;
  final error = (result['error'] as Map?)?.cast<String, Object?>();
  final cause = switch (error?['host_error']) {
    final int key when key > 0 => yt._hostErrors.remove(key)?.error,
    _ => null,
  };
  yt._hostErrors.removeWhere((_, e) => e.call == id);
  if (error == null) {
    completer.complete(result['value']);
    return;
  }
  completer.completeError(InnertubeError(
    error['message'] as String? ?? 'YouTube.js failed',
    error['info'],
    name: error['name'] as String? ?? 'Error',
    stack: error['stack'] as String?,
    cause: cause,
  ));
}

/// Answers what JavaScript asked of the owner: a fetch through the caller's
/// transport, or the cache.
Future<void> _runAsk(YouTubei yt, int id, int call, String kind, Map<String, Object?> fields) async {
  final token = CancellationToken();
  yt._asks[id] = (call: call, token: token);
  // An ask a cancelled call made after its cancellation fails at once.
  if (call != 0 && !yt._calls.containsKey(call)) token.cancel();
  try {
    token.throwIfCancelled();
    final (Object? value, Uint8List? bytes) = switch (kind) {
      'fetch' => await _fetchAsk(yt, fields['request']! as Map, token),
      'cacheGet' || 'cacheSet' || 'cacheRemove' => await _cacheAsk(kind, fields),
      _ => throw UnsupportedError('unknown ask $kind'),
    };
    token.throwIfCancelled();
    yt._commands.send(_Answered(
      id,
      jsonEncode({'id': id, 'value': value}),
      bytes == null ? null : TransferableTypedData.fromList([bytes]),
    ));
  } catch (error) {
    final key = ++yt._nextHostError;
    yt._hostErrors[key] = (call: call, error: error);
    yt._commands.send(_Answered(id, jsonEncode({
      'id': id,
      'error': {'message': '$error', 'host_error': key},
    }), null));
  } finally {
    yt._asks.remove(id);
  }
}

Future<(Object?, Uint8List?)> _fetchAsk(YouTubei yt, Map request, CancellationToken token) async {
  final response = await yt._fetch(FetchRequest(
    url: request['url'] as String,
    method: request['method'] as String,
    headers: [for (final h in request['headers'] as List) ((h as List)[0] as String, h[1] as String)],
    body: switch (request['body']) {
      final String body => base64.decode(body),
      _ => null,
    },
  ), token);
  return (
    {
      'url': response.url,
      'status': response.status,
      'headers': [for (final (k, v) in response.headers) [k, v]],
    },
    response.body,
  );
}

/// Platform's Cache in JavaScript, answered by [UniversalCache]'s files.
Future<(Object?, Uint8List?)> _cacheAsk(String kind, Map<String, Object?> fields) async {
  final directory = fields['directory']! as String;
  final key = fields['key']! as String;
  switch (kind) {
    case 'cacheGet':
      return (null, await cacheGet(directory, key));
    case 'cacheSet':
      await cacheSet(directory, key, base64.decode(fields['data']! as String));
    case 'cacheRemove':
      await cacheRemove(directory, key);
  }
  return (null, null);
}

// Messages from the owner to the engine isolate.

final class _Invoke {
  const _Invoke(this.id, this.expression, this.args);
  final int id;
  final String expression;
  final String args;
}

final class _Cancel {
  const _Cancel(this.id);
  final int id;
}

final class _Answered {
  const _Answered(this.id, this.json, this.body);
  final int id;
  final String json;
  final TransferableTypedData? body;
}

final class _Close {
  const _Close();
}

// Messages from the engine isolate to the owner.

final class _Ready {
  const _Ready(this.commands);
  final SendPort commands;
}

final class _StartFailed {
  const _StartFailed(this.message);
  final String message;
}

final class _LoadFailed {
  const _LoadFailed(this.message);
  final String message;
}

/// A fetch or cache ask from JavaScript, made while [call] ran.
final class _Ask {
  const _Ask(this.id, this.call, this.kind, this.fields);
  final int id;
  final int call;
  final String kind;
  final Map<String, Object?> fields;
}

final class _Log {
  const _Log(this.level, this.message);
  final String level;
  final String message;
}

final class _Done {
  const _Done(this.id, this.result);
  final int id;
  final Map<String, Object?> result;
}

final class _Fault {
  const _Fault(this.message);
  final String message;
}

final class _Exited {
  const _Exited();
}

// The engine isolate.

final class _Engine {
  _Engine(this.owner, this.commands);
  final SendPort owner;
  final ReceivePort commands;
  late final Pointer<YtEngine> native;

  /// Calls accepted and neither done nor cancelled.
  final pending = <int>{};
  final cancelled = <int>{};

  /// The call that made each ask and timer.
  final askCalls = <int, int>{};
  final timers = <int, ({int call, Timer timer})>{};

  /// The call the JavaScript running now works for, 0 when unknown.
  var running = 0;
  var closing = false;
  final random = Random.secure();
}

void _engineMain((SendPort, int, TransferableTypedData?) args) {
  final (owner, interruptAddress, bundle) = args;
  final e = _Engine(owner, ReceivePort('youtubei engine'));
  final native = yt_new(_memoryLimit, _stackLimit, Pointer.fromAddress(interruptAddress));
  if (native == nullptr) {
    owner.send(const _StartFailed('create the QuickJS runtime'));
    owner.send(const _Exited());
    return;
  }
  e.native = native;
  final error = _load(native, bundle?.materialize().asUint8List()) ?? _pump(e) ?? _drain(e, 0);
  if (error != null) {
    _free(e);
    owner.send(_LoadFailed(error));
    owner.send(const _Exited());
    return;
  }
  e.commands.listen((message) => _onCommand(e, message));
  owner.send(_Ready(e.commands.sendPort));
}

/// Evaluates the scripts with [bundle], zero-terminated as JS_Eval wants,
/// or the built-in bundle.
String? _load(Pointer<YtEngine> native, Uint8List? bundle) {
  if (bundle == null) return _take(yt_load(native, nullptr, 0));
  return using((arena) {
    final source = arena<Uint8>(bundle.length + 1);
    source.asTypedList(bundle.length).setAll(0, bundle);
    source[bundle.length] = 0;
    return _take(yt_load(native, source.cast(), bundle.length));
  });
}

void _onCommand(_Engine e, Object? message) {
  switch (message) {
    case _Invoke(:final id, :final expression, :final args):
      e.pending.add(id);
      final error = using((arena) => _run(e, id, () => yt_eval(
        e.native,
        '__invoke($id, ($expression), $args)'.toNativeUtf8(allocator: arena).cast(),
        'call.js'.toNativeUtf8(allocator: arena).cast(),
      )));
      if (error != null && e.pending.remove(id)) {
        e.owner.send(_Done(id, {'error': {'message': error}}));
      }
    case _Cancel(:final id):
      e.cancelled.add(id);
      e.pending.remove(id);
    case _Answered(:final id, :final json, :final body):
      final call = e.askCalls.remove(id) ?? 0;
      final bytes = body?.materialize().asUint8List();
      _deliver(e, call, '__answer', json, bytes);
    case _Close():
      e.closing = true;
  }
  _exitIfDrained(e);
}

/// Runs [action] for [call], then the promise jobs it queued, then acts on
/// the outbox. Returns the error of a failed [action].
String? _run(_Engine e, int call, Pointer<Char> Function() action) {
  e.running = call;
  yt_set_running(e.native, call);
  final error = _take(action());
  final fault = _pump(e) ?? _drain(e, call);
  if (fault != null) e.owner.send(_Fault(fault));
  return error;
}

/// Acts on what JavaScript queued while [call] ran. Answers that need
/// JavaScript again wait for a later microtask, so JavaScript never runs
/// inside this. Returns an error taking the outbox.
String? _drain(_Engine e, int call) {
  final (error, text) = using((arena) {
    final out = arena<Pointer<Char>>()..value = nullptr;
    final error = _take(yt_take_outbox(e.native, out));
    return (error, _take(out.value) ?? '');
  });
  if (error != null || text.isEmpty) return error;
  for (final message in (jsonDecode(text) as List).cast<Map<String, Object?>>()) {
    switch (message['kind']) {
      case 'done':
        final id = message['id']! as int;
        final result = (jsonDecode(message['result']! as String) as Map).cast<String, Object?>();
        if (e.pending.remove(id)) e.owner.send(_Done(id, result));
      case final String kind when kind == 'fetch' || kind.startsWith('cache'):
        final id = message['id']! as int;
        e.askCalls[id] = call;
        e.owner.send(_Ask(id, call, kind, message));
      case 'digest':
        final id = message['id']! as int;
        final (json, bytes) = _digest(id, message);
        scheduleMicrotask(() {
          _deliver(e, call, '__answer', json, bytes);
          _exitIfDrained(e);
        });
      case 'timer':
        final id = message['id']! as int;
        final delay = message['delay']! as num;
        e.timers[id] = (call: call, timer: Timer(Duration(milliseconds: max(0, delay.toInt())), () {
          e.timers.remove(id);
          _deliver(e, call, '__fireTimer', '{"id":$id}', null);
          _exitIfDrained(e);
        }));
      case 'clearTimer':
        e.timers.remove(message['id']! as int)?.timer.cancel();
      case 'log':
        e.owner.send(_Log(message['level']! as String, message['message']! as String));
      case final kind:
        e.owner.send(_Fault('unknown outbox message $kind'));
    }
  }
  return null;
}

(String, Uint8List?) _digest(int id, Map<String, Object?> message) {
  try {
    final hash = switch ((message['algorithm']! as String).toUpperCase()) {
      'SHA-1' => sha1, // Required by YouTube's existing protocol.
      'SHA-256' => sha256,
      final other => throw UnsupportedError('unsupported digest "$other"'),
    };
    return (jsonEncode({'id': id}), Uint8List.fromList(hash.convert(base64.decode(message['data']! as String)).bytes));
  } catch (error) {
    return (jsonEncode({'id': id, 'error': {'message': '$error'}}), null);
  }
}

void _deliver(_Engine e, int call, String function, String json, Uint8List? bytes) {
  final error = using((arena) {
    final name = function.toNativeUtf8(allocator: arena).cast<Char>();
    final encoded = utf8.encode(json);
    // Zero-terminated, as JS_ParseJSON reads.
    final text = arena<Uint8>(encoded.length + 1)..asTypedList(encoded.length + 1).setAll(0, [...encoded, 0]);
    final data = bytes == null ? nullptr : (arena<Uint8>(max(bytes.length, 1))..asTypedList(bytes.length).setAll(0, bytes));
    return _run(e, call, () => yt_deliver(e.native, name, text.cast(), encoded.length, data, bytes?.length ?? 0));
  });
  if (error != null && !_interrupted(e, call, error)) e.owner.send(_Fault(error));
}

/// Runs every pending job. A job interrupted because its call was cancelled
/// leaves the others queued; they run unattributed. Returns another failure.
String? _pump(_Engine e) {
  for (;;) {
    final error = _take(yt_pump(e.native));
    if (error == null) break;
    if (!_interrupted(e, e.running, error)) return error;
    e.running = 0;
    yt_set_running(e.native, 0);
  }
  e.running = 0;
  yt_set_running(e.native, 0);
  return null;
}

bool _interrupted(_Engine e, int call, String error) =>
  (e.cancelled.contains(call) || e.closing) && error.startsWith('InternalError: interrupted');

void _exitIfDrained(_Engine e) {
  if (!e.closing || e.pending.isNotEmpty) return;
  _free(e);
  e.owner.send(const _Exited());
}

void _free(_Engine e) {
  for (final timer in e.timers.values) {
    timer.timer.cancel();
  }
  e.timers.clear();
  e.commands.close();
  yt_free(e.native);
}

String? _take(Pointer<Char> error) {
  if (error == nullptr) return null;
  try {
    return error.cast<Utf8>().toDartString();
  } finally {
    yt_string_free(error);
  }
}
