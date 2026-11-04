import 'package:PiliPlus/plugin/pl_player/backend/fake_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/native_session_host.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_route.dart';
import 'package:PiliPlus/plugin/pl_player/backend/source_identity.dart';
import 'package:PiliPlus/plugin/pl_player/capability.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'dart:io';

import '../support/hive_test_env.dart';
import 'package:flutter_test/flutter_test.dart';

/// The production wiring, not a re-implementation of it.
///
/// The bug these tests exist for: `PlPlayerController.setDataSource` bumped its
/// own counter, `openNativeHdr` bumped it again and `PlaybackSession` bumped a
/// third, so the first native open left the controller on generation 2 while
/// the session emitted generation 1. Every event was then dropped as stale and
/// the picture played with a frozen progress bar. Nothing here stamps a
/// generation by hand on the way in: the allocator and the host do it.

PlaybackRequest _request({
  String key = 'BV1:100:120:hvc1.1.6',
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  setUpAll(() async {
    tempDir = await setUpTestStorage();
  });
  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  group('generation has one allocator', () {
    test('each media switch allocates exactly one generation', () {
      final allocator = SourceGenerationAllocator();
      expect(allocator.beginSourceChange(), 1);
      expect(allocator.beginSourceChange(), 2);
      expect(allocator.current, 2);
      expect(allocator.isCurrent(2), isTrue);
      expect(allocator.isCurrent(1), isFalse);
    });

    test('the session stores the generation the facade allocated', () async {
      final host = NativeSessionHost(
        backendFor: (generation, sessionId) => FakePlaybackBackend(
          kind: PlaybackBackendKind.native,
          generation: generation,
        ),
      );
      await host.open(
        generation: 7,
        sessionId: 'BV1:100:120:hvc1.1.6',
        request: _request(),
      );
      // The session must not have invented its own number.
      expect(host.session!.generation, 7);
      await host.close();
    });
  });

  group('first native open reaches the UI', () {
    test('an event with the opened generation is forwarded', () async {
      final controller = PlPlayerController.forTesting();
      final backend = FakePlaybackBackend(
        kind: PlaybackBackendKind.native,
        generation: 1,
        readyAfterOpen: false,
      );
      controller.nativeBackendOverride = (gen, sessionId) => backend;
      final host = NativeSessionHost(
        onSnapshot: controller.debugOnNativeSnapshot,
        backendFor: controller.debugNativeBackendFactory,
      );
      controller.debugAdoptNativeHost(host);
      final generation = controller.debugBeginSourceChange();
      await host.open(
        generation: generation,
        sessionId: 'k',
        request: _request(),
      );

      backend.emit(
        PlaybackSnapshot(
          generation: generation,
          backend: PlaybackBackendKind.native,
          position: const Duration(seconds: 12),
          duration: const Duration(minutes: 10),
          ready: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.snapshot.position.inSeconds, 12);
      expect(controller.snapshot.backend, PlaybackBackendKind.native);
      expect(controller.snapshot.duration.inMinutes, 10);
      await host.close();
    });

    test('a buffering event still reaches the UI on the first open', () async {
      final controller = PlPlayerController.forTesting();
      final backend = FakePlaybackBackend(
        kind: PlaybackBackendKind.native,
        generation: 1,
        readyAfterOpen: false,
      );
      controller.nativeBackendOverride = (gen, sessionId) => backend;
      final host = NativeSessionHost(
        onSnapshot: controller.debugOnNativeSnapshot,
        backendFor: controller.debugNativeBackendFactory,
      );
      final generation = controller.debugBeginSourceChange();
      await host.open(
        generation: generation,
        sessionId: 'k',
        request: _request(autoPlay: false),
      );

      backend.emit(
        PlaybackSnapshot(
          generation: generation,
          backend: PlaybackBackendKind.native,
          position: const Duration(seconds: 4),
          buffering: true,
          ready: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.isBuffering.value, isTrue);
      expect(controller.snapshot.position.inSeconds, 4);
      await host.close();
    });

    test('a late event from the previous generation is refused', () async {
      final controller = PlPlayerController.forTesting();
      final first = FakePlaybackBackend(
        kind: PlaybackBackendKind.native,
        generation: 1,
        readyAfterOpen: false,
      );
      final second = FakePlaybackBackend(
        kind: PlaybackBackendKind.native,
        generation: 2,
        readyAfterOpen: false,
      );
      final host = NativeSessionHost(
        onSnapshot: controller.debugOnNativeSnapshot,
        backendFor: (gen, id) => first,
      );
      controller.debugAdoptNativeHost(host);

      final genOne = controller.debugBeginSourceChange();
      await host.open(generation: genOne, sessionId: 'a', request: _request());

      // A switch: new generation, new backend, same reduction path.
      final genTwo = controller.debugBeginSourceChange();
      final secondHost = NativeSessionHost(
        onSnapshot: controller.debugOnNativeSnapshot,
        backendFor: (gen, id) => second,
      );
      controller.debugAdoptNativeHost(secondHost);
      await secondHost.open(
        generation: genTwo,
        sessionId: 'b',
        request: _request(key: 'b'),
      );

      second.emit(
        PlaybackSnapshot(
          generation: genTwo,
          backend: PlaybackBackendKind.native,
          position: const Duration(seconds: 20),
          ready: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final afterNew = controller.snapshot.position;

      // The superseded session still emits: it must not paint over the new one.
      first.emit(
        PlaybackSnapshot(
          generation: genOne,
          backend: PlaybackBackendKind.native,
          position: const Duration(seconds: 300),
          ready: true,
        ),
      );
      // And an event that a re-stamping implementation would have accepted.
      first.emit(
        const PlaybackSnapshot(
          generation: 1,
          backend: PlaybackBackendKind.native,
          position: Duration(seconds: 600),
          ready: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(afterNew.inSeconds, 20);
      expect(controller.snapshot.position.inSeconds, 20);
      await secondHost.close();
    });

    test('a same-source retry gets a fresh generation', () {
      final controller = PlPlayerController.forTesting();
      final first = controller.debugBeginSourceChange();
      final second = controller.debugBeginSourceChange();
      expect(second, greaterThan(first));
      expect(controller.generation, second);
    });
  });

  group('route and capabilities follow the backend', () {
    test('none, preparing and disposed are distinguishable', () {
      final controller = PlPlayerController.forTesting();
      expect(controller.route, PlaybackRoute.none);
      controller.debugSetRoute(PlaybackRoute.preparing);
      expect(controller.route, PlaybackRoute.preparing);
      expect(controller.capabilities.shader, isFalse);
      expect(
        controller.capabilities.unsupportedReason('截图', controller.route),
        contains('准备'),
      );
      controller.debugSetRoute(PlaybackRoute.disposed);
      expect(controller.capabilities.audioOnly, isFalse);
    });

    test('an mpv route offers shaders; a native one does not', () {
      const mpv = PlaybackCapabilities(isMpv: true, route: PlaybackRoute.mpv);
      const native = PlaybackCapabilities(
        isMpv: false,
        route: PlaybackRoute.native,
      );
      expect(mpv.shader, isTrue);
      expect(native.shader, isFalse);
      expect(native.screenshot, isFalse);
      expect(native.audioOnly, isFalse);
      expect(native.pip, isFalse);
    });
  });

  group('unsupported actions are refused without a player', () {
    test('the native route is not offered a texture screenshot', () {
      final controller = PlPlayerController.forTesting();
      controller.debugSetRoute(PlaybackRoute.native);
      expect(controller.capabilities.screenshot, isFalse);
      expect(controller.capabilities.textureScreenshot, isFalse);
      // takeScreenshot() explains the refusal through a toast, which needs a
      // dialog host; the gate it consults is the assertable part here.
    });

    test('captureFrame on the native route returns null', () async {
      final controller = PlPlayerController.forTesting();
      controller.debugSetRoute(PlaybackRoute.native);
      expect(await controller.captureFrame(), isNull);
    });

    test('setAudioOnly does not change the flag when unsupported', () async {
      final controller = PlPlayerController.forTesting();
      controller.debugSetRoute(PlaybackRoute.native);
      expect(await controller.setAudioOnly(true), isFalse);
      expect(controller.onlyPlayAudio.value, isFalse);
    });

    test('setShader is refused on the native route and keeps the preference',
        () async {
      final controller = PlPlayerController.forTesting();
      controller.debugSetRoute(PlaybackRoute.native);
      final before = controller.superResolutionType.value;
      expect(await controller.setShader(), isFalse);
      expect(controller.superResolutionType.value, before);
    });
  });
}
