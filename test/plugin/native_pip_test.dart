import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/native_pip.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// PiP on the native path, exercised through the real coordinator and a fake
/// platform channel - not by re-implementing the state machine in the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final control = MethodChannel(NativePipCoordinator.controlChannelForTest);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) handler;

  setUp(() {
    calls = [];
    handler = (call) async {
      calls.add(call);
      return null;
    };
    messenger.setMockMethodCallHandler(control, (call) async {
      return handler(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(control, null);
  });

  test('start is refused before a session is bound', () async {
    final coordinator = NativePipCoordinator();
    final status = await coordinator.start();
    // Refused locally: no channel call was made, and the reason is stated.
    expect(status.state, NativePipState.failed);
    expect(status.message, isNotNull);
    expect(calls, isEmpty);
    await coordinator.dispose();
  });

  test('start sends the bound session id and reports progress', () async {
    final coordinator = NativePipCoordinator();
    await coordinator.bind('BV1:100:120:hvc1');
    expect(coordinator.status.value.state, NativePipState.idle);

    final status = await coordinator.start();
    expect(calls.single.method, 'pipStart');
    expect(calls.single.arguments['sessionId'], 'BV1:100:120:hvc1');
    expect(status.state, NativePipState.starting);
    await coordinator.dispose();
  });

  test('a native failure is surfaced instead of being swallowed', () async {
    handler = (call) async {
      calls.add(call);
      throw PlatformException(code: 'pip_failed', message: 'not-possible');
    };
    final coordinator = NativePipCoordinator();
    await coordinator.bind('a');
    final status = await coordinator.start();
    expect(status.state, NativePipState.failed);
    expect(status.message, isNotNull);
    await coordinator.dispose();
  });

  test('a second start while active is not sent twice', () async {
    final coordinator = NativePipCoordinator();
    await coordinator.bind('a');
    await coordinator.start();
    // Simulate the native "started" event.
    await coordinator.debugHandleEvent({
      'event': 'pip',
      'sessionId': 'a',
      'state': 'started',
    });
    expect(coordinator.status.value.state, NativePipState.active);
    await coordinator.start();
    expect(calls.length, 1, reason: 'already showing');
    await coordinator.dispose();
  });

  test('events for a superseded session are ignored', () async {
    final coordinator = NativePipCoordinator();
    await coordinator.bind('old');
    await coordinator.bind('new');
    await coordinator.debugHandleEvent({
      'event': 'pip',
      'sessionId': 'old',
      'state': 'started',
    });
    expect(coordinator.status.value.state, isNot(NativePipState.active));
    expect(coordinator.status.value.sessionId, 'new');
    await coordinator.dispose();
  });

  test('stop is idempotent and bounded', () async {
    final coordinator = NativePipCoordinator();
    await coordinator.bind('a');
    await coordinator.stop();
    await coordinator.stop();
    expect(calls.where((c) => c.method == 'pipStop').length, 2);
    await coordinator.dispose();
  });

  test('interruption is forwarded so the session does not resume over it',
      () async {
    final coordinator = NativePipCoordinator();
    await coordinator.bind('a');
    await coordinator.setInterrupted(true);
    expect(calls.single.method, 'setInterrupted');
    expect(calls.single.arguments['interrupted'], isTrue);
    await coordinator.dispose();
  });

  test('both backends can offer PiP, through different implementations', () {
    expect(NativePipCoordinator.supports(PlaybackRoute.native), isTrue);
    expect(NativePipCoordinator.supports(PlaybackRoute.mpv), isTrue);
    expect(NativePipCoordinator.supports(PlaybackRoute.preparing), isFalse);
    expect(NativePipCoordinator.supports(PlaybackRoute.disposed), isFalse);
  });
}
