import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/fake_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/native_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

PlaybackRequest _request({
  String key = 'a',
  Duration? start,
  bool autoPlay = true,
  double rate = 1.0,
}) => PlaybackRequest(
  sourceKey: key,
  videoUrl: 'https://cdn.example/v.mp4',
  audioUrl: 'https://cdn.example/a.mp4',
  startPosition: start,
  autoPlay: autoPlay,
  rate: rate,
);

void main() {
  test('the previous backend is disposed before the new one opens', () async {
    final session = PlaybackSession();
    final first = FakePlaybackBackend();
    final second = FakePlaybackBackend(kind: PlaybackBackendKind.native);

    await session.open(first, _request(key: 'first'));
    await session.open(second, _request(key: 'second'));

    expect(first.disposed, isTrue, reason: 'two decoders must not coexist');
    expect(second.disposed, isFalse);
    expect(session.activeKind, PlaybackBackendKind.native);
    await session.dispose();
  });

  test('an event from a superseded generation never reaches the UI', () async {
    final session = PlaybackSession();
    final first = FakePlaybackBackend();
    final second = FakePlaybackBackend(kind: PlaybackBackendKind.native);

    await session.open(first, _request(key: 'first'));
    await session.open(second, _request(key: 'second'));

    final seen = <PlaybackSnapshot>[];
    final sub = session.events.listen(seen.add);
    await Future<void>.delayed(Duration.zero);
    seen.clear();
    // The old backend was disposed, but a queued event can still arrive.
    first.emit(
      const PlaybackSnapshot(
        generation: 1,
        backend: PlaybackBackendKind.mpv,
        position: Duration(seconds: 300),
        ready: true,
      ),
    );
    second.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.native,
        position: const Duration(seconds: 10),
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(seen.map((s) => s.position.inSeconds), [10]);
    await sub.cancel();
    await session.dispose();
  });

  test('position and milliseconds come from one snapshot', () async {
    final session = PlaybackSession();
    final backend = FakePlaybackBackend();
    await session.open(backend, _request());

    backend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 2),
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.snapshot.position.inSeconds, 10);
    expect(session.snapshot.positionInMilliseconds, 10000);
    expect(session.snapshot.durationInMilliseconds, 120000);
    await session.dispose();
  });

  test('autoPlay=false is not undone when the source becomes ready', () async {
    final session = PlaybackSession();
    final backend = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(backend, _request(autoPlay: false));

    backend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(backend.calls, isNot(contains('play')));
    await session.dispose();
  });

  test('a pause during preparation survives readiness', () async {
    final session = PlaybackSession();
    final backend = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(backend, _request());
    await session.pause();

    // The backend reports itself playing as soon as it is ready, which is what
    // the old AVPlayer path did unconditionally in its completion handler.
    backend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        ready: true,
        playing: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(backend.calls.last, 'pause');
    await session.dispose();
  });

  test('the newest seek wins while the source is still preparing', () async {
    final session = PlaybackSession();
    final backend = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(backend, _request(start: const Duration(seconds: 3)));

    await session.seek(const Duration(seconds: 40));
    await session.seek(const Duration(seconds: 75));

    backend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        ready: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final seeks = backend.calls.where((c) => c.startsWith('seek:')).toList();
    expect(seeks, ['seek:75000']);
    await session.dispose();
  });

  test('a rate set before ready is applied once', () async {
    final session = PlaybackSession();
    final backend = FakePlaybackBackend(readyAfterOpen: false);
    await session.open(backend, _request(rate: 1.5));
    await session.setRate(2.0);

    backend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        ready: true,
        rate: 1.0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(backend.calls.where((c) => c.startsWith('rate:')), ['rate:2.0']);
    await session.dispose();
  });

  test('a duration already reported is not cleared by a later zero', () async {
    final session = PlaybackSession();
    final backend = FakePlaybackBackend();
    await session.open(backend, _request());

    backend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        duration: const Duration(minutes: 3),
        ready: true,
      ),
    );
    backend.emit(
      PlaybackSnapshot(
        generation: session.generation,
        backend: PlaybackBackendKind.mpv,
        duration: Duration.zero,
        position: const Duration(seconds: 5),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.snapshot.durationInMilliseconds, 180000);
    expect(session.snapshot.position.inSeconds, 5);
    await session.dispose();
  });

  test('dispose stops forwarding and releases the backend', () async {
    final session = PlaybackSession();
    final backend = FakePlaybackBackend();
    await session.open(backend, _request());
    await session.dispose();

    expect(backend.disposed, isTrue);
    expect(session.hasSource, isFalse);
    // A late event after dispose must not throw.
    backend.emit(const PlaybackSnapshot(ready: true));
  });

  group('native snapshot parsing', () {
    test('seconds become one Duration, not two disagreeing fields', () {
      final snapshot = NativeParseFixture.parse({
        'seconds': 12.5,
        'duration': 600.0,
        'rate': 1.0,
        'ready': true,
      });
      expect(snapshot.positionInMilliseconds, 12500);
      expect(snapshot.durationInMilliseconds, 600000);
      expect(snapshot.playing, isTrue);
    });

    test('an unknown duration stays zero instead of becoming NaN', () {
      final snapshot = NativeParseFixture.parse({
        'seconds': 1.0,
        'duration': double.infinity,
        'rate': 0,
        'ready': true,
      });
      expect(snapshot.hasDuration, isFalse);
      expect(snapshot.playing, isFalse);
    });
  });
}

/// Keeps the test independent of the MethodChannel plumbing in
/// [NativePlaybackBackend] while exercising the same conversion.
abstract final class NativeParseFixture {
  static PlaybackSnapshot parse(Map<String, Object?> map) =>
      NativePlaybackBackend.parse(map, 7);
}
