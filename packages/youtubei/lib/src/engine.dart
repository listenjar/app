// The YouTube.js engine, ported from the Go youtubei crate's engine.go.
//
// One QuickJS runtime lives in its own isolate, which owns every JavaScript
// value and runs YouTube.js's promise jobs, timers and host calls. The owner
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

import 'bindings.g.dart';
import 'models.dart';

/// The transport YouTube.js's fetch goes through.
typedef Fetch = Future<FetchResponse> Function(FetchRequest request, CancellationToken token);

const _memoryLimit = 768 << 20;
// Dart runs isolates on threads with small native stacks; stay well inside.
const _stackLimit = 512 << 10;

/// A running engine. Use it through [initialize], [playlistHead],
/// [continuation], [videoInfo], [channel], [search], [decipher], [release]
/// and [callYouTubei]; stop it with [closeYouTubei].
final class YouTubei {
  YouTubei._(this._fetch, this._interrupt, this._events);

  final Fetch _fetch;
  final Pointer<YtInterrupt> _interrupt;
  final ReceivePort _events;
  late final SendPort _commands;
  final _exited = Completer<void>();
  final _calls = <int, CancellableCompleter<Object?>>{};
  final _fetches = <int, ({int call, CancellationToken token})>{};
  final _hostErrors = <int, ({int call, Object error})>{};
  var _nextCall = 0;
  var _nextHostError = 0;
  var _closing = false;
}

/// Starts an engine: a new isolate evaluates the embedded YouTube.js.
Future<YouTubei> startYouTubei(Fetch fetch, {CancellationToken? token}) async {
  token?.throwIfCancelled();
  final interrupt = yt_interrupt_new();
  if (interrupt == nullptr) throw StateError('allocate the QuickJS interrupt');
  final yt = YouTubei._(fetch, interrupt, ReceivePort('youtubei'));
  final ready = CancellableCompleter<void>(token, onCancel: () => yt_interrupt_close(interrupt));
  yt._events.listen((message) => _onEvent(yt, message, ready));
  try {
    await Isolate.spawn(_engineMain, (yt._events.sendPort, interrupt.address), debugName: 'youtubei');
  } catch (_) {
    _dispose(yt);
    rethrow;
  }
  await ready.future;
  return yt;
}

/// Stops accepting calls, waits for accepted ones to finish, then frees the
/// runtime. Cancel the calls' tokens to stop them sooner.
Future<void> closeYouTubei(YouTubei yt) async {
  if (!yt._closing) {
    yt._closing = true;
    yt._commands.send(const _Close());
  }
  await yt._exited.future;
}

/// Calls `expression(args)` in YouTube.js and returns its JSON value. Prefer
/// the typed operations; this is the escape hatch for upstream methods they
/// do not cover.
Future<Object?> callYouTubei(YouTubei yt, String expression, Object? args, {CancellationToken? token}) async {
  if (yt._closing) throw StateError('YouTube runtime closed');
  token?.throwIfCancelled();
  final id = ++yt._nextCall;
  final completer = CancellableCompleter<Object?>(token, onCancel: () => _cancelCall(yt, id));
  yt._calls[id] = completer;
  yt._commands.send(_Invoke(id, expression, jsonEncode(args)));
  return completer.future;
}

Future<Session> initialize(YouTubei yt, SessionOptions options, {CancellationToken? token}) async =>
  sessionFromJson(await callYouTubei(yt, '__bridge.initialize', sessionOptionsJson(options), token: token));

/// The first page of a playlist, with no videos it marks unavailable hidden.
Future<Playlist> playlistHead(YouTubei yt, String id, {CancellationToken? token}) async =>
  playlistFromJson(await callYouTubei(yt, '__bridge.playlistHead', id, token: token));

/// The page after [page]; consumes [page]'s handle.
Future<Playlist> continuation(YouTubei yt, Playlist page, {CancellationToken? token}) async =>
  playlistFromJson(await callYouTubei(yt, '__bridge.continuation', page.handle, token: token));

Future<VideoInfo> videoInfo(YouTubei yt, String id, Client client, {CancellationToken? token}) async =>
  videoInfoFromJson(await callYouTubei(yt, '__bridge.videoInfo', {'id': id, 'client': client.value}, token: token));

/// A channel from its link (`/channel/UC…`, `/@handle`, `/c/…`, `/user/…`):
/// YouTube resolves a handle to its id, then reads the channel's metadata.
Future<Channel> channel(YouTubei yt, String url, {CancellationToken? token}) async =>
  channelFromJson(await callYouTubei(yt, '__bridge.channel', url, token: token));

/// What YouTube's search lists for [query], in its order: videos, channels,
/// playlists and the shelves between them.
Future<List<SearchItem>> search(YouTubei yt, String query, {CancellationToken? token}) async =>
  searchFromJson(await callYouTubei(yt, '__bridge.search', query, token: token));

/// The playable URL of [format], loading the player when it needs one.
Future<String> decipher(YouTubei yt, Format format, {CancellationToken? token}) async =>
  await callYouTubei(yt, '__bridge.decipher', format.handle, token: token) as String;

/// Frees live handles: formats, or playlist pages not continued.
Future<void> release(YouTubei yt, Iterable<int> handles, {CancellationToken? token}) =>
  callYouTubei(yt, '__bridge.release', handles.toList(), token: token);

void _cancelCall(YouTubei yt, int id) {
  if (yt._calls.remove(id) == null) return;
  yt_interrupt_cancel(yt._interrupt, id);
  yt._commands.send(_Cancel(id));
  for (final fetch in yt._fetches.values) {
    if (fetch.call == id) fetch.token.cancel();
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
    case _FetchStart(:final id, :final call, :final request):
      unawaited(_runFetch(yt, id, call, request));
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
  completer.completeError(YouTubeiException(
    error['message'] as String? ?? 'YouTube.js failed',
    stack: error['stack'] as String?,
    info: error['info'],
    playabilityStatus: playabilityFromJson(error['playability_status']),
    cause: cause,
  ));
}

Future<void> _runFetch(YouTubei yt, int id, int call, FetchRequest request) async {
  final token = CancellationToken();
  yt._fetches[id] = (call: call, token: token);
  // A fetch a cancelled call started after its cancellation fails at once.
  if (call != 0 && !yt._calls.containsKey(call)) token.cancel();
  try {
    final response = await yt._fetch(request, token);
    token.throwIfCancelled();
    yt._commands.send(_FetchDone(id, jsonEncode({
      'id': id,
      'response': {
        'url': response.url,
        'status': response.status,
        'headers': [for (final (k, v) in response.headers) [k, v]],
      },
    }), TransferableTypedData.fromList([response.body])));
  } catch (error) {
    final key = ++yt._nextHostError;
    yt._hostErrors[key] = (call: call, error: error);
    yt._commands.send(_FetchDone(id, jsonEncode({
      'id': id,
      'error': {'message': '$error', 'host_error': key},
    }), null));
  } finally {
    yt._fetches.remove(id);
  }
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

final class _FetchDone {
  const _FetchDone(this.id, this.json, this.body);
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

final class _FetchStart {
  const _FetchStart(this.id, this.call, this.request);
  final int id;
  final int call;
  final FetchRequest request;
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
  late final NativeCallable<YtHostFunction> host;

  /// Calls accepted and neither done nor cancelled.
  final pending = <int>{};
  final cancelled = <int>{};

  /// The call that started each fetch and timer.
  final fetchCalls = <int, int>{};
  final timers = <int, ({int call, Timer timer})>{};
  var nextFetch = 0;

  /// The call the JavaScript running now works for, 0 when unknown.
  var running = 0;
  var closing = false;
  final random = Random.secure();
}

void _engineMain((SendPort, int) args) {
  final (owner, interruptAddress) = args;
  final e = _Engine(owner, ReceivePort('youtubei engine'));
  e.host = NativeCallable<YtHostFunction>.isolateLocal(
    (Pointer<YtEngine> native, Pointer<Char> name, Pointer<Char> args, int length) =>
      _hostCall(e, native, name.cast<Utf8>().toDartString(), args.cast<Utf8>().toDartString(length: length)),
  );
  final native = yt_new(_memoryLimit, _stackLimit, Pointer.fromAddress(interruptAddress), e.host.nativeFunction);
  if (native == nullptr) {
    e.host.close();
    owner.send(const _StartFailed('create the QuickJS runtime'));
    owner.send(const _Exited());
    return;
  }
  e.native = native;
  final error = _take(yt_load(native)) ?? _pump(e);
  if (error != null) {
    _free(e);
    owner.send(_StartFailed(error));
    owner.send(const _Exited());
    return;
  }
  e.commands.listen((message) => _onCommand(e, message));
  owner.send(_Ready(e.commands.sendPort));
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
    case _FetchDone(:final id, :final json, :final body):
      final call = e.fetchCalls.remove(id) ?? 0;
      final bytes = body?.materialize().asUint8List();
      _deliver(e, call, '__hostFetchSettle', json, bytes);
    case _Close():
      e.closing = true;
  }
  _exitIfDrained(e);
}

/// Runs [action] for [call], then the promise jobs it queued. Returns the
/// error of a failed [action].
String? _run(_Engine e, int call, Pointer<Char> Function() action) {
  e.running = call;
  yt_set_running(e.native, call);
  final error = _take(action());
  final fault = _pump(e);
  if (fault != null) e.owner.send(_Fault(fault));
  return error;
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
  e.host.close();
}

String? _take(Pointer<Char> error) {
  if (error == nullptr) return null;
  try {
    return error.cast<Utf8>().toDartString();
  } finally {
    yt_string_free(error);
  }
}

/// Answers JavaScript's synchronous __host(name, json).
void _hostCall(_Engine e, Pointer<YtEngine> native, String name, String args) {
  try {
    switch (name) {
      case 'done':
        final result = (jsonDecode(args) as Map).cast<String, Object?>();
        final id = result['id'] as int;
        if (e.pending.remove(id)) e.owner.send(_Done(id, result));
        _return(native, 'U');
      case 'fetch':
        final request = (jsonDecode(args) as Map).cast<String, Object?>();
        final id = ++e.nextFetch;
        e.fetchCalls[id] = e.running;
        e.owner.send(_FetchStart(id, e.running, FetchRequest(
          url: request['url'] as String,
          method: request['method'] as String,
          headers: [for (final h in request['headers'] as List) ((h as List)[0] as String, h[1] as String)],
          body: switch (request['body']) {
            final String body => base64.decode(body),
            _ => null,
          },
        )));
        _return(native, 'J', utf8.encode('$id'));
      case 'randomUUID':
        _return(native, 'S', utf8.encode(_uuid(e.random)));
      case 'randomBytes':
        final count = jsonDecode(args) as int;
        if (count < 0 || count > 65536) throw RangeError('invalid random byte length $count');
        _return(native, 'B', Uint8List.fromList([for (var i = 0; i < count; i++) e.random.nextInt(256)]));
      case 'digest':
        final [algorithm as String, data as String] = jsonDecode(args) as List;
        final hash = switch (algorithm.toUpperCase()) {
          'SHA-1' => sha1, // Required by YouTube's existing protocol.
          'SHA-256' => sha256,
          _ => throw UnsupportedError('unsupported digest "$algorithm"'),
        };
        _return(native, 'B', Uint8List.fromList(hash.convert(base64.decode(data)).bytes));
      case 'parseURL':
        final [input as String, base as String] = jsonDecode(args) as List;
        _return(native, 'J', utf8.encode(jsonEncode(_parseURL(input, base))));
      case 'setTimer':
        final [id as int, delay as num] = jsonDecode(args) as List;
        final call = e.running;
        e.timers[id] = (call: call, timer: Timer(Duration(milliseconds: max(0, delay.toInt())), () {
          e.timers.remove(id);
          _deliver(e, call, '__fireTimer', '{"id":$id}', null);
          _exitIfDrained(e);
        }));
        _return(native, 'U');
      case 'clearTimer':
        e.timers.remove(jsonDecode(args) as int)?.timer.cancel();
        _return(native, 'U');
      default:
        throw UnsupportedError('unknown host call $name');
    }
  } catch (error) {
    _return(native, 'E', utf8.encode('$error'));
  }
}

void _return(Pointer<YtEngine> native, String kind, [List<int> data = const []]) => using((arena) {
  final bytes = arena<Uint8>(max(data.length, 1))..asTypedList(data.length).setAll(0, data);
  yt_host_return(native, kind.codeUnitAt(0), bytes, data.length);
});

String _uuid(Random random) {
  final b = [for (var i = 0; i < 16; i++) random.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = [for (final v in b) v.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
    '${hex.substring(16, 20)}-${hex.substring(20)}';
}

Map<String, String> _parseURL(String input, String base) {
  var uri = Uri.parse(input);
  if (base.isNotEmpty) uri = Uri.parse(base).resolveUri(uri);
  if (!uri.hasScheme) throw const FormatException('URL must be absolute');
  final [username, password] = switch (uri.userInfo.indexOf(':')) {
    -1 => [uri.userInfo, ''],
    final i => [uri.userInfo.substring(0, i), uri.userInfo.substring(i + 1)],
  };
  final hostname = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final port = uri.hasPort ? '${uri.port}' : '';
  final host = port.isEmpty ? hostname : '$hostname:$port';
  return {
    'protocol': '${uri.scheme}:',
    'username': Uri.decodeComponent(username),
    'password': Uri.decodeComponent(password),
    'host': host,
    'hostname': hostname,
    'port': port,
    'pathname': uri.path.isEmpty ? '/' : uri.path,
    'search': uri.hasQuery ? '?${uri.query}' : '',
    'hash': uri.hasFragment ? '#${uri.fragment}' : '',
    'origin': '${uri.scheme}://$host',
  };
}
