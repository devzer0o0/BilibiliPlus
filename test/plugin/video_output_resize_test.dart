import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/utils/video_output_size.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldResizeVideoOutput', () {
    // Super-resolution shaders must see the full source, and the resize API
    // needs hardware decoding, so both gates have to hold.
    test('enabled only with hardware decoding and no super resolution', () {
      expect(
        shouldResizeVideoOutput(
          hardwareDecoding: true,
          superResolutionDisabled: true,
        ),
        isTrue,
      );
    });

    test('software decoding disables resizing', () {
      expect(
        shouldResizeVideoOutput(
          hardwareDecoding: false,
          superResolutionDisabled: true,
        ),
        isFalse,
      );
    });

    test('an active super-resolution shader disables resizing', () {
      expect(
        shouldResizeVideoOutput(
          hardwareDecoding: true,
          superResolutionDisabled: false,
        ),
        isFalse,
      );
    });

    test('both off stays off', () {
      expect(
        shouldResizeVideoOutput(
          hardwareDecoding: false,
          superResolutionDisabled: false,
        ),
        isFalse,
      );
    });
  });

  group('VideoOutputResize', () {
    late List<Size> sent;
    late List<Object> errors;
    late VideoOutputResize resize;

    setUp(() {
      sent = <Size>[];
      errors = <Object>[];
      resize = VideoOutputResize(
        resize: (size) async => sent.add(size),
        onError: (e, _) => errors.add(e),
      );
    });

    // The coordinator debounces by 120 ms, so every assertion advances time.
    Future<void> settle([int ms = 200]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    // The first request is sent even before the native side reports a size;
    // _schedule only bails when _output already equals _target.
    test('the first request is sent before the output reports', () async {
      resize.request(const Size(1280, 720));
      await settle();
      expect(sent, [const Size(1280, 720)]);
    });

    test('a request is applied once the output size is known', () async {
      resize.outputChanged(const Size(1920, 1080));
      resize.request(const Size(1280, 720));
      await settle();
      expect(sent, [const Size(1280, 720)]);
    });

    test('repeated identical requests are coalesced', () async {
      resize.outputChanged(const Size(1920, 1080));
      resize.request(const Size(1280, 720));
      resize.request(const Size(1280, 720));
      resize.request(const Size(1280, 720));
      await settle();
      expect(sent.length, lessThanOrEqualTo(2));
    });

    test('a request matching the current output is skipped', () async {
      resize.outputChanged(const Size(1280, 720));
      resize.request(const Size(1280, 720));
      await settle();
      expect(sent, isEmpty);
    });

    test('suspend drops a pending change', () async {
      resize.outputChanged(const Size(1920, 1080));
      resize.request(const Size(1280, 720));
      resize.suspend();
      await settle();
      expect(sent, isEmpty);
    });

    test('dispose stops further work', () async {
      resize.outputChanged(const Size(1920, 1080));
      resize.request(const Size(1280, 720));
      resize.dispose();
      await settle();
      expect(sent, isEmpty);
    });

    test('a failing native call is reported, not thrown', () async {
      final failing = VideoOutputResize(
        resize: (_) async => throw StateError('native'),
        onError: (e, _) => errors.add(e),
      );
      failing.outputChanged(const Size(1920, 1080));
      failing.request(const Size(1280, 720));
      await settle();
      expect(errors, isNotEmpty);
    });
  });
}