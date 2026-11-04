import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/fake_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Switching source must keep what the user asked for.
///
/// The old updatePlayer read the position from mpv (absent on the native path,
/// so it seeked to zero) and forced autoplay on (a paused player started
/// playing). These exercise the session rules directly with the request shape
/// the page now builds.
PlaybackRequest _request({
  String key = 'k',
  Duration? start,
  bool autoPlay = true,
  double rate = 1.0,
  int qn = 120,
}) => PlaybackRequest(
  sourceKey: '$key:$qn',
  videoUrl: 'https://cdn.example/$qn.mp4',
  audioUrl: 'https://cdn.example/a.m4s',
  startPosition: start,
  autoPlay: autoPlay,
  rate: rate,
);

void main() {
  test('a paused player stays paused after a quality switch', () async {
    final session = PlaybackSession();
    final first = FakePlaybackBackend(readyAfterOpen: true);
    await session.open(first, _request(qn: 120));
    await session.pause();

    // The page builds the switch request from the user's intent, not from a
    // hardcoded autoplay=true.
    final second = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(second, _request(qn: 80, autoPlay: false));
    second.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        ready: true,
        playing: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(second.calls, isNot(contains('play')));
    expect(second.calls.last, 'pause');
    await session.dispose();
  });

  test('the rate survives a source switch', () async {
    final session = PlaybackSession();
    final first = FakePlaybackBackend();
    await session.open(first, _request(rate: 1.0));
    await session.setRate(1.5);

    final second = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(second, _request(qn: 80, rate: 1.5));
    second.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        ready: true,
        rate: 1.0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    // 1.5 was the user's rate; the backend reporting 1.0 must not reset it.
    expect(second.calls.where((c) => c.startsWith('rate:')), ['rate:1.5']);
    await session.dispose();
  });

  test('the position is carried into the new source, not reset to zero',
      () async {
    final session = PlaybackSession();
    final first = FakePlaybackBackend();
    await session.open(first, _request(qn: 120));
    first.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        position: const Duration(minutes: 12, seconds: 34),
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.snapshot.position.inMinutes, 12);

    final second = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(
      second,
      _request(qn: 80, start: session.snapshot.position),
    );
    second.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final seeks = second.calls.where((c) => c.startsWith('seek:')).toList();
    expect(seeks, ['seek:754000']);
    await session.dispose();
  });

  test('a slow old request does not overwrite the newer selection', () async {
    final session = PlaybackSession();
    final oldBackend = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(oldBackend, _request(qn: 120));
    final oldGeneration = session.generation;

    final newBackend = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(newBackend, _request(qn: 64));
    newBackend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        position: const Duration(seconds: 5),
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    // The superseded open finishes last and reports its own state.
    oldBackend.emit(
      PlaybackSnapshot(
        generation: oldGeneration,
        backend: PlaybackBackendKind.mpv,
        position: const Duration(seconds: 300),
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.snapshot.position.inSeconds, 5);
    await session.dispose();
  });
}
