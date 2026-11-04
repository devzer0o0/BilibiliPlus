import 'package:PiliPlus/plugin/pl_player/backend/backend_factory.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const factory = BackendFactory();

  group('backend selection is exclusive', () {
    test('a 10-bit rendition on iOS goes native', () {
      if (!factory.supportsNativeHdrPathForTest) return;
      expect(
        factory.kindFor(tenBitRendition: true, isFileSource: false),
        PlaybackBackendKind.native,
      );
    });

    test('SDR never starts the native player', () {
      expect(
        factory.kindFor(tenBitRendition: false, isFileSource: false),
        PlaybackBackendKind.mpv,
      );
    });

    test('a local file stays on mpv even when it is 10-bit', () {
      expect(
        factory.kindFor(tenBitRendition: true, isFileSource: true),
        PlaybackBackendKind.mpv,
      );
    });

    test('no rendition produces both backends', () {
      for (final tenBit in [true, false]) {
        for (final file in [true, false]) {
          final kind = factory.kindFor(
            tenBitRendition: tenBit,
            isFileSource: file,
          );
          expect(
            PlaybackBackendKind.values.where((k) => k == kind).length,
            1,
            reason: 'exactly one backend for tenBit=$tenBit file=$file',
          );
        }
      }
    });
  });
}
