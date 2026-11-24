// Windows' System Media Transport Controls for the player: the media overlay
// that the volume keys raise, the lock screen, and the keyboard's media
// keys. audio_service covers every other platform; on Windows it does
// nothing, so this mirrors its state into SMTC and sends SMTC's buttons
// back to the player (player.dart).
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:smtc_windows/smtc_windows.dart';

final class WindowsMedia {
  WindowsMedia._(this._smtc, this._subscriptions);

  final SMTCWindows _smtc;
  final List<StreamSubscription<Object?>> _subscriptions;

  static Future<WindowsMedia?> start(BaseAudioHandler player) async {
    try {
      await SMTCWindows.initialize();
    } catch (_) {
      return null;
    }
    final smtc = SMTCWindows(
      config: const SMTCConfig(
        playEnabled: true,
        pauseEnabled: true,
        stopEnabled: false,
        nextEnabled: true,
        prevEnabled: true,
        fastForwardEnabled: true,
        rewindEnabled: true,
      ),
      enabled: false,
    );
    final subscriptions = <StreamSubscription<Object?>>[];
    subscriptions
      ..add(smtc.buttonPressStream.listen((button) {
        unawaited(switch (button) {
          PressedButton.play => player.play(),
          PressedButton.pause => player.pause(),
          PressedButton.next => player.skipToNext(),
          PressedButton.previous => player.skipToPrevious(),
          PressedButton.fastForward => player.fastForward(),
          PressedButton.rewind => player.rewind(),
          PressedButton.stop => player.stop(),
          _ => Future<void>.value(),
        });
      }))
      ..add(player.mediaItem.listen((item) async {
        if (item == null) {
          await smtc.clearMetadata();
          await smtc.disableSmtc();
          return;
        }
        await smtc.enableSmtc();
        await smtc.updateMetadata(MusicMetadata(
          title: item.title,
          artist: item.artist,
          album: item.album,
          albumArtist: item.artist,
          thumbnail: item.artUri?.toString(),
        ));
      }))
      ..add(player.playbackState.listen((state) async {
        if (player.mediaItem.value == null) return;
        await smtc.setPlaybackStatus(state.playing ? PlaybackStatus.playing : PlaybackStatus.paused);
        final end = player.mediaItem.value?.duration;
        await smtc.updateTimeline(PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: end?.inMilliseconds ?? 0,
          positionMs: state.updatePosition.inMilliseconds,
          minSeekTimeMs: 0,
          maxSeekTimeMs: end?.inMilliseconds ?? 0,
        ));
      }));
    return WindowsMedia._(smtc, subscriptions);
  }

  Future<void> dispose() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _smtc.dispose();
  }
}
