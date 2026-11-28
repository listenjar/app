// The podcast player: one audio player for the app's life (just_audio;
// libmpv through media_kit on Windows and Linux), handed to the system as
// its media session (audio_service: the lock screen, Control Centre,
// Android's media notification, macOS Now Playing and media keys, MPRIS on
// Linux; Windows' media overlay through windows_media.dart). It plays one
// episode at a time and Up Next after it, resumes where the listener
// stopped, remembers the speed, and keeps the sleep timer. Headphone and
// keyboard next/previous skip within the episode by default, like most
// podcast players. No widgets here.
import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'chapters.dart';
import 'downloads.dart';
import 'library.dart';
import 'log.dart';
import 'media_chapters.dart';
import 'stream_server.dart';
import 'transfer.dart' as transfer;
import 'windows_media.dart';
import 'youtube.dart';

final _log = Logger('player');

/// How often the position is saved while playing.
const _saveEvery = Duration(seconds: 5);

/// Closer than this to the end counts as finished when the listener leaves.
const _nearEnd = Duration(seconds: 20);

/// Before the sleep timer pauses, the volume fades for this long.
const _fade = Duration(seconds: 8);

const speeds = [0.8, 1.0, 1.1, 1.2, 1.3, 1.5, 1.7, 2.0, 2.5, 3.0];

/// When the sleep timer stops playback.
sealed class SleepTimer {
  const SleepTimer();
}

/// At a moment.
final class SleepAt extends SleepTimer {
  const SleepAt(this.at, this.length);
  final DateTime at;

  /// What the listener asked for, to show beside the countdown.
  final Duration length;
}

/// When the episode playing ends.
final class SleepAtEnd extends SleepTimer {
  const SleepAtEnd();
}

final class Player extends BaseAudioHandler with ChangeNotifier {
  Player._(this._library, this._youtube, this._downloads);

  final Library _library;
  final YouTubeService _youtube;
  final Downloads _downloads;
  final _audio = AudioPlayer(handleInterruptions: true, handleAudioSessionActivation: true);
  final _life = CancellationToken();

  /// Carries YouTube's streams to the audio player.
  final _http = HttpClient()..userAgent = null;
  late final _streams = StreamServer(_http);
  final _subscriptions = <StreamSubscription<Object?>>[];
  WindowsMedia? _windows;

  /// Starts the player and hands it to the system. Restores what was
  /// playing when the app last stopped, paused where it was.
  static Future<Player> start(Library library, YouTubeService youtube, Downloads downloads) async {
    JustAudioMediaKit.title = 'Listenjar';
    try {
      JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
    } catch (e) {
      // Linux without libmpv: the library still opens; each play reports
      // the error instead.
      _log.severe('Audio unavailable', e);
    }
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    final player = Player._(library, youtube, downloads);
    final settings = library.settings;
    try {
      await AudioService.init(
        builder: () => player,
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.listenjar.desktop.playback',
          // On Linux this names the player to the desktop (MPRIS Identity).
          androidNotificationChannelName: Platform.isLinux ? 'Listenjar' : 'Playback',
          androidStopForegroundOnPause: true,
          fastForwardInterval: settings.skipForward,
          rewindInterval: settings.skipBack,
          preloadArtwork: true,
        ),
      );
    } catch (e) {
      // The player still plays in the window without the system's controls.
      _log.warning('Media session unavailable', e);
    }
    if (Platform.isWindows) player._windows = await WindowsMedia.start(player);
    // The listener's speed, before anything loads.
    await player._audio.setSpeed(settings.speed);
    player._listen();
    player._restore();
    return player;
  }

  /// The episode loaded, playing or not.
  PodcastEpisode? get current => _current;
  PodcastEpisode? _current;

  /// Whether [_current] is in the audio player yet; a restored episode
  /// loads on first play.
  bool _prepared = false;

  /// [_current]'s load and then its source in the audio player: one at a
  /// time. Another episode or [stop] cancels it, with its YouTube lookups
  /// and the ranges its stream is fetching, so a load the listener left
  /// never reaches the audio player and nothing plays twice.
  CancellationToken? _load;

  /// [_load]'s result, which a play or seek during the load waits for
  /// rather than loading the episode a second time.
  Future<bool>? _preparing;

  /// Looking up or buffering the episode.
  bool get loading => _loading;
  bool _loading = false;

  /// Why the episode couldn't play, until another plays.
  Object? get error => _error;
  Object? _error;

  /// [error] as the listener reads it.
  String? get problem => switch (_error) {
    null => null,
    StateError(:final message) => message,
    SignInRequired() => 'YouTube wants to confirm you’re not a bot before it plays this. Try again later.',
    RateLimited() => 'YouTube is limiting this device for now. Try again in a few minutes.',
    MediaUnavailable() => 'YouTube refused to stream this video. Try again in a few minutes.',
    SocketException() || TlsException() || HttpException() || TimeoutException() => 'Couldn’t reach the podcast’s server. Check your connection and try again.',
    final PlayerException e when _transient(e) => 'Couldn’t reach the podcast’s server. Check your connection and try again.',
    PlayerException(:final message) => 'Couldn’t play this episode${message == null || message.isEmpty ? '' : ': $message'}.',
    final e => 'Couldn’t play this episode: $e',
  };

  bool get playing => _audio.playing;
  double get speed => _audio.speed;
  Duration get position => _audio.position;
  Duration? get duration => _audio.duration ?? _current?.duration;
  Stream<Duration> get positionStream => _audio.positionStream;
  Stream<Duration> get bufferedStream => _audio.bufferedPositionStream;

  /// The chapters of the episode loaded, from the audio's own metadata (its
  /// download, or its stream) or, for a YouTube video, from YouTube; none
  /// until it loads. Kept in memory only, for this episode.
  List<Chapter> get chapters => _chapters;
  List<Chapter> _chapters = const [];

  /// To the start of the next chapter.
  Future<void> nextChapter() async {
    final list = chapters;
    final i = chapterAt(list, position);
    if (i + 1 < list.length) await seek(list[i + 1].start);
  }

  /// To the start of this chapter, or of the one before when this one
  /// has only just begun.
  Future<void> previousChapter() async {
    final list = chapters;
    final at = position;
    final i = chapterAt(list, at);
    if (i < 0) return;
    final back = i > 0 && at - list[i].start < _chapterRestart ? i - 1 : i;
    await seek(list[back].start);
  }

  /// Within this much of a chapter's start, previous goes to the one before.
  static const _chapterRestart = Duration(seconds: 3);

  SleepTimer? get sleep => _sleep;
  SleepTimer? _sleep;
  Timer? _sleepTimer;
  Timer? _saving;

  /// The furthest the loaded episode has played since it loaded.
  Duration _reached = Duration.zero;

  /// A stream that ends further than this before the episode's end
  /// dropped, rather than finished.
  static const _cutShort = Duration(minutes: 1);

  /// Where the loaded episode last played: [position] goes to zero when
  /// its source fails.
  Duration _at = Duration.zero;

  /// Where the next load starts instead of the saved position: where the
  /// episode was when its source failed.
  Duration? _resumeAt;

  /// Network failures since the episode last made progress.
  int _failures = 0;

  /// Tries at loading or playing through a network failure, waiting longer
  /// before each: connections that a network resets now and then (the
  /// TLS handshake, mostly) get through on the next try.
  static const _attempts = 4;
  static Duration _backoff(int failures) => Duration(seconds: 1 << (failures - 1));

  /// A failure of the network on the way, which the next try may not meet.
  static bool _transient(Object e) => switch (e) {
    SocketException() || TlsException() || HttpException() => true,
    // AVPlayer's NSURLError (timed out, host not found or unreachable,
    // connection lost, offline, TLS failed); ExoPlayer's source (I/O)
    // errors; libmpv's failure to open the URL.
    PlayerException(:final code, :final message) =>
      Platform.isMacOS || Platform.isIOS
        ? const {-1001, -1003, -1004, -1005, -1006, -1009, -1200}.contains(code)
        : Platform.isAndroid
        ? code == 0
        : (message ?? '').startsWith('Failed to open'),
    _ => false,
  };

  void _listen() {
    _subscriptions
      ..add(_audio.playbackEventStream.listen((_) {
        _reachedNow();
        _broadcast();
      }, onError: _playbackFailed))
      // Playback events come only on changes (AVPlayer sends none while it
      // just plays), so the ticking position keeps [_reached] current.
      ..add(_audio.positionStream.listen((_) => _reachedNow()))
      ..add(_audio.playingStream.listen(_playingChanged))
      ..add(_audio.processingStateStream.listen((state) {
        if (state == ProcessingState.completed) unawaited(_finished());
        _broadcast();
      }))
      ..add(_audio.durationStream.listen((d) {
        final current = _current;
        if (d == null || current == null || d <= Duration.zero) return;
        if (current.duration == null || (current.duration! - d).abs() > const Duration(seconds: 2)) {
          _library.setDuration(current.id, d);
        }
        mediaItem.add(mediaItem.value?.copyWith(duration: d));
        notifyListeners();
      }));
    _library.addListener(_libraryChanged);
  }

  /// At its end media_kit reports the position as zero, so where playback
  /// got to is kept while it plays.
  void _reachedNow() {
    if (_audio.processingState == ProcessingState.completed) return;
    final at = _audio.position;
    if (at > Duration.zero) _at = at;
    if (at > _reached) {
      _reached = at;
      _failures = 0;
    }
  }

  /// The audio player's source failed while loaded: through a network
  /// failure it loads again where it was, and plays on if it was playing.
  void _playbackFailed(Object e) {
    // A load in flight tries again, or reports, on its own.
    if (_preparing != null) return;
    if (_current == null || !_prepared || !_transient(e) || _failures + 1 >= _attempts) {
      _failed(e);
      return;
    }
    unawaited(_recover(e));
  }

  Future<void> _recover(Object e) async {
    final episode = _current!;
    final playing = _audio.playing;
    _failures++;
    _prepared = false;
    _resumeAt = _at;
    _loading = true;
    _log.info('Playback of episode ${episode.id} failed at $_at; loading again', e);
    notifyListeners();
    _broadcast();
    try {
      await Future<void>.delayed(_backoff(_failures)).asCancellable(_life);
    } on CancelledException {
      return;
    }
    // The listener moved on, or played it again, meanwhile.
    if (_current?.id != episode.id || _prepared || _preparing != null) {
      if (_preparing == null && _loading) {
        _loading = false;
        notifyListeners();
        _broadcast();
      }
      return;
    }
    if (!await _prepare()) return;
    if (playing) unawaited(_audio.play());
  }

  /// Keeps the loaded episode's row fresh (downloaded, renamed, played).
  void _libraryChanged() {
    final current = _current;
    if (current == null) return;
    final fresh = _library.episode(current.id);
    if (fresh == null) {
      unawaited(stop());
      return;
    }
    _current = fresh;
  }

  void _restore() {
    final id = _library.nowPlaying;
    final episode = id == null ? null : _library.episode(id);
    if (episode == null) return;
    _current = episode;
    _prepared = false;
    mediaItem.add(_item(episode));
    _broadcast();
    notifyListeners();
  }

  MediaItem _item(PodcastEpisode e) => MediaItem(
    id: '${e.id}',
    title: e.title,
    album: e.podcastTitle,
    artist: e.from,
    duration: e.duration,
    artUri: switch (e.artwork) {
      final url? => Uri.tryParse(url),
      null => null,
    },
  );

  /// Plays [episode] from where the listener stopped in it, or from the
  /// start if they finished it. Started on its show's page, listed
  /// [oldestFirst] or not, it plays on into the show's next ([following]).
  Future<void> playEpisode(PodcastEpisode episode, {bool start = true, bool? oldestFirst}) async {
    // Loaded or loading already: one load, one playback.
    if (_current?.id == episode.id && (_prepared || _preparing != null)) {
      if (oldestFirst != null) _showOrder = oldestFirst;
      if (start) await play();
      return;
    }
    _savePosition();
    _cancelLoad();
    _showOrder = oldestFirst;
    _current = episode;
    _prepared = false;
    _resumeAt = null;
    _failures = 0;
    _error = null;
    _chapters = const [];
    _library.nowPlaying = episode.id;
    _library.dequeue(episode.id);
    mediaItem.add(_item(episode));
    notifyListeners();
    if (start) await play();
  }

  /// The order of the show page the episode was started on (oldest first or
  /// not); null when it was started anywhere else, and then only Up Next
  /// plays after it. Kept until the app closes.
  bool? _showOrder;

  /// What plays when the episode ends with Up Next empty: the next
  /// unplayed episode of its show, in the order its page listed them.
  PodcastEpisode? get following {
    final current = _current;
    final oldestFirst = _showOrder;
    if (current == null || oldestFirst == null) return null;
    final list = _library.episodes(current.podcastId, oldestFirst: oldestFirst);
    final at = list.indexWhere((e) => e.id == current.id);
    if (at < 0) return null;
    return list.skip(at + 1).where((e) => !e.played).firstOrNull;
  }

  /// Plays the first in Up Next, else [following]; false with neither.
  Future<bool> _playOn() async {
    if (_library.takeNext() case final next?) {
      await playEpisode(next);
      return true;
    }
    if (following case final next?) {
      await playEpisode(next, oldestFirst: _showOrder);
      return true;
    }
    return false;
  }

  /// Puts [_current] in the audio player, or waits for the load already
  /// doing it. False when it can't play or another episode replaced it.
  Future<bool> _prepare() {
    final episode = _current;
    if (episode == null) return Future.value(false);
    if (_prepared) return Future.value(true);
    if (_preparing case final preparing?) return preparing;
    // A spent source's (the episode finished) stream.
    _load?.cancel();
    final load = CancellationToken();
    _load = load;
    final preparing = _loadEpisode(episode, load);
    _preparing = preparing;
    return preparing;
  }

  /// Cancels the load in flight, if any.
  void _cancelLoad() {
    _load?.cancel();
    _load = null;
    _preparing = null;
  }

  Future<bool> _loadEpisode(PodcastEpisode episode, CancellationToken load) async {
    final token = _life.merge(load);
    _loading = true;
    _error = null;
    notifyListeners();
    _broadcast();
    // Loading again after the source failed: where it was, as it was.
    final resume = _resumeAt;
    _resumeAt = null;
    try {
      for (var attempt = 1;; attempt++) {
        try {
          final (source, chapters) = await traced(_log, 'source for “${episode.title}”', () => _source(episode, token));
          // Checked right before the audio player takes the source, so only the
          // newest load ever reaches it.
          token.throwIfCancelled();
          final from = resume ??
            (episode.played || (episode.duration != null && episode.duration! - episode.position < _nearEnd)
              ? Duration.zero
              : episode.position);
          if (resume == null) _reached = from;
          _at = from;
          // Heard again, a played episode is in progress again.
          if (episode.played) _library.setPlayed([episode.id], false);
          await _audio.setAudioSource(source, initialPosition: from);
          token.throwIfCancelled();
          await _audio.setSpeed(_library.settings.speed);
          _prepared = true;
          unawaited(_findChapters(episode, chapters));
          return true;
        } catch (e) {
          // A replaced load ends quietly: the audio player interrupts its
          // source when the next one's arrives.
          if (token.isCancelled) return false;
          if (attempt >= _attempts || !_transient(e)) {
            _failed(e);
            return false;
          }
          _log.info('Loading episode ${episode.id} failed (try $attempt); trying again', e);
          await Future<void>.delayed(_backoff(attempt)).asCancellable(token);
        }
      }
    } on CancelledException {
      return false;
    } finally {
      if (identical(_load, load)) {
        _preparing = null;
        if (!_prepared) _cancelLoad();
        _loading = false;
        notifyListeners();
        _broadcast();
      }
    }
  }

  /// Where [episode]'s audio comes from: its download, its feed's URL, or
  /// YouTube's stream, looked up now since YouTube's links expire, with the
  /// video's chapters from the same lookup. [token] is the load's, so a
  /// replaced load stops fetching the stream too.
  Future<(AudioSource, List<Chapter>?)> _source(PodcastEpisode episode, CancellationToken token) async {
    if (episode.downloaded) {
      final file = _library.downloadFile(episode)!;
      if (await file.exists()) return (AudioSource.file(file.path), null);
      _library.setDownload(episode.id, DownloadState.none);
    }
    if (episode.youtubeId case final id?) {
      final lookup = token.merge(TimeoutCancellationToken(const Duration(seconds: 60)));
      final session = await _youtube.session(lookup);
      // Chapters are kept once found, so the next response is asked for
      // only the first time.
      final kept = _library.youtubeChapters(id);
      final (media, reason) = await session.media(id, channel: false, chapters: kept == null, token: lookup);
      if (media == null) throw StateError(reason ?? 'YouTube won’t play this video');
      _library.fillVideoDetails(episode.id, description: media.description, publishedAt: media.publishedAt);
      if (media.chapters case final found?) _library.keepYouTubeChapters(id, found);
      final length = await transfer.mediaLength(_http, media.audio, lookup);
      // AVPlayer gets an HLS playlist; ExoPlayer and libmpv read the index
      // in the file themselves.
      final hls = Platform.isMacOS || Platform.isIOS;
      return (AudioSource.uri(await _streams.serve(media.audio, length, media.contentType, token, hls: hls)), kept ?? media.chapters);
    }
    final url = episode.audioUrl;
    if (url == null) throw StateError('This episode has no audio');
    return (AudioSource.uri(Uri.parse(url)), null);
  }

  /// [episode]'s chapters, once it loads: [found] with its YouTube stream,
  /// else its download's own; else, for a YouTube video (a Listenjar Cloud
  /// episode, a download without them), YouTube's, kept on this device once
  /// found, and for a podcast episode, its stream's own, read with range
  /// requests. Without any of those, the ones its show notes list; for a
  /// podcast episode those show at once, until its audio's own are read.
  Future<void> _findChapters(PodcastEpisode episode, List<Chapter>? found) async {
    // Loaded again (it finished, and plays again): already found.
    if (found == null && _chapters.isNotEmpty) return;
    var chapters = found ?? const <Chapter>[];
    final written = found == null ? notesChapters(_library.description(episode.id)) : const <Chapter>[];
    if (written.isNotEmpty && episode.videoId == null && _current?.id == episode.id) {
      _chapters = written;
      notifyListeners();
    }
    try {
      if (found == null && episode.downloaded) {
        final file = _library.downloadFile(episode)!;
        chapters = await traced(_log, 'chapters in ${file.path}', () => fileChapters(file), describe: (c) => '${c.length} chapters');
      }
      if (found == null && chapters.isEmpty) {
        final token = _life.merge(TimeoutCancellationToken(const Duration(seconds: 60)));
        if (episode.videoId case final id?) {
          chapters = _library.youtubeChapters(id) ?? await _youtubeChapters(id, token);
        } else if (!episode.downloaded && episode.audioUrl != null) {
          final url = Uri.parse(episode.audioUrl!);
          chapters = await traced(_log, 'chapters in ${url.host}${url.path}', () => streamChapters(_http, url, token), describe: (c) => '${c.length} chapters');
        }
      }
    } catch (e) {
      // Without chapters it plays the same.
      _log.fine('No chapters for episode ${episode.id}', e);
    }
    if (chapters.isEmpty) chapters = written;
    if (_current?.id != episode.id || chapters.isEmpty) return;
    _chapters = chapters;
    notifyListeners();
  }

  /// The YouTube video [id]'s chapters, asked of YouTube and kept, once it
  /// answers, for good.
  Future<List<Chapter>> _youtubeChapters(String id, CancellationToken token) async {
    final session = await _youtube.session(token);
    final found = await traced(_log, 'chapters of $id', () => session.chapters(id, token), describe: (c) => '${c?.length} chapters');
    if (found == null) return const [];
    _library.keepYouTubeChapters(id, found);
    return found;
  }

  void _failed(Object e) {
    _error = e;
    _loading = false;
    _log.warning('Playback failed', e);
    notifyListeners();
    _broadcast();
  }

  void _playingChanged(bool playing) {
    _saving?.cancel();
    if (playing) {
      _saving = Timer.periodic(_saveEvery, (_) => _savePosition());
    } else {
      _savePosition(notify: true);
    }
    notifyListeners();
  }

  void _savePosition({bool notify = false}) {
    final current = _current;
    if (current == null || !_prepared) return;
    final position = _audio.position;
    if (position <= Duration.zero) return;
    _library.savePosition(current.id, position, notify: notify);
  }

  /// The episode ended: it's played, its download may go, and Up Next (or
  /// its show's next) plays on unless the sleep timer was waiting for the
  /// end.
  Future<void> _finished() async {
    final done = _current;
    if (done == null) return;
    _saving?.cancel();
    // The source is spent: the next play loads it again.
    _prepared = false;
    final end = _audio.duration ?? done.duration;
    if (end != null && end - _reached > _cutShort) {
      _library.savePosition(done.id, _reached, notify: true);
      _failed(StateError('The audio stopped early. Play picks up where it stopped.'));
      return;
    }
    _library.setPlayed([done.id], true);
    // Settings, Storage: a played download may go now.
    await tidyDownloads(_library, _downloads);
    if (_sleep is SleepAtEnd) {
      setSleep(null);
      await _audio.pause();
      await _audio.seek(Duration.zero);
      return;
    }
    if (!await _playOn()) {
      await _audio.pause();
      await _audio.seek(Duration.zero);
    }
  }

  @override
  Future<void> play() async {
    if (_current == null) {
      final next = _library.takeNext();
      if (next == null) return;
      return playEpisode(next);
    }
    if (!await _prepare()) return;
    // Resolves when playback stops, not when it starts.
    unawaited(_audio.play());
  }

  @override
  Future<void> pause() => _audio.pause();

  Future<void> toggle() => playing ? pause() : play();

  @override
  Future<void> seek(Duration position) async {
    if (!_prepared && !await _prepare()) return;
    final end = duration;
    final clamped = position < Duration.zero ? Duration.zero : (end != null && position > end ? end : position);
    await _audio.seek(clamped);
    _savePosition();
  }

  @override
  Future<void> fastForward() => seek(position + _library.settings.skipForward);

  @override
  Future<void> rewind() => seek(position - _library.settings.skipBack);

  @override
  Future<void> skipToNext() async {
    if (_library.settings.remoteSkips) return fastForward();
    return playNext();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_library.settings.remoteSkips) return rewind();
    return seek(Duration.zero);
  }

  /// Leaves the episode for the first one in Up Next, else its show's next.
  Future<void> playNext() async {
    final current = _current;
    if (current != null && duration != null && duration! - position < _nearEnd) _library.setPlayed([current.id], true);
    await _playOn();
  }

  @override
  Future<void> stop() async {
    _savePosition(notify: true);
    _cancelLoad();
    await _audio.stop();
    _current = null;
    _prepared = false;
    _resumeAt = null;
    _showOrder = null;
    _library.nowPlaying = null;
    mediaItem.add(null);
    setSleep(null);
    notifyListeners();
    _broadcast();
  }

  @override
  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.5, 3.0).toDouble();
    await _audio.setSpeed(s);
    _library.updateSettings(_library.settings.copyWith(speed: s));
    notifyListeners();
    _broadcast();
  }

  /// Marks the episode loaded as played and moves on.
  Future<void> markPlayedAndNext() async {
    final current = _current;
    if (current == null) return;
    _library.setPlayed([current.id], true);
    if (!await _playOn()) await stop();
  }

  // The sleep timer.

  void setSleep(SleepTimer? timer) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    unawaited(_audio.setVolume(1));
    _sleep = timer;
    if (timer case SleepAt(:final at)) {
      _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick(at));
    }
    notifyListeners();
  }

  /// Adds time to a running timer, as a listener drifting off does.
  void extendSleep(Duration more) {
    if (_sleep case SleepAt(:final at, :final length)) {
      final from = at.isBefore(DateTime.now()) ? DateTime.now() : at;
      setSleep(SleepAt(from.add(more), length + more));
    }
  }

  void _tick(DateTime at) {
    final left = at.difference(DateTime.now());
    if (left <= Duration.zero) {
      setSleep(null);
      unawaited(_audio.pause().then((_) => _audio.setVolume(1)));
      return;
    }
    if (left < _fade && playing) unawaited(_audio.setVolume(left.inMilliseconds / _fade.inMilliseconds));
    notifyListeners();
  }

  /// What the system's controls show and offer.
  void _broadcast() {
    final playing = _audio.playing;
    final state = switch (_audio.processingState) {
      _ when _loading => AudioProcessingState.loading,
      _ when _error != null => AudioProcessingState.error,
      ProcessingState.idle => _current == null ? AudioProcessingState.idle : AudioProcessingState.ready,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: state,
      playing: playing,
      updatePosition: _audio.position,
      bufferedPosition: _audio.bufferedPosition,
      speed: _audio.speed,
      errorMessage: _error?.toString(),
    ));
  }

  // The system's other requests.

  @override
  Future<void> onTaskRemoved() async {
    // Swiped away on Android while paused: nothing left to keep running.
    if (!playing) await stop();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        await toggle();
      case MediaButton.next:
        await skipToNext();
      case MediaButton.previous:
        await skipToPrevious();
    }
  }

  @override
  Future<void> dispose() async {
    _savePosition();
    _life.cancel();
    _saving?.cancel();
    _sleepTimer?.cancel();
    _library.removeListener(_libraryChanged);
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _windows?.dispose();
    await _audio.dispose();
    await _streams.close();
    _http.close(force: true);
    super.dispose();
  }
}
