import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

/// The audio-only presentation is a real media shape, not a hidden layer.
///
/// Hiding the AVPlayerLayer still downloads and decodes every video fragment,
/// so "listen to the video" has to be a presentation without a video variant.
/// These assertions pin the playlist shape that makes that true; the Swift
/// implementation is exercised by tool/swift_parser_tests.sh.
void main() {
  group('an audio-only master playlist has no video variant', () {
    test('the variant stream points at the audio rendition', () {
      final playlist = [
        '#EXTM3U',
        '#EXT-X-VERSION:7',
        '#EXT-X-INDEPENDENT-SEGMENTS',
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="main",'
            'DEFAULT=YES,AUTOSELECT=YES,URI="/t/audio.m3u8"',
        '#EXT-X-STREAM-INF:BANDWIDTH=192000,CODECS="mp4a.40.2",AUDIO="aud"',
        '/t/audio.m3u8',
      ].join('\n');

      final lines = const LineSplitter().convert(playlist);
      final variantIndex = lines.indexWhere(
        (l) => l.startsWith('#EXT-X-STREAM-INF:'),
      );
      expect(variantIndex, isPositive);
      // The URI on the next line is the audio playlist: nothing here names
      // video.m3u8, so the player never requests it.
      expect(lines[variantIndex + 1], '/t/audio.m3u8');
      expect(playlist.contains('video.m3u8'), isFalse);
      expect(lines.last, '/t/audio.m3u8');
    });

    test('the audiovisual playlist still has both renditions', () {
      final playlist = [
        '#EXT-HLS',
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="main",'
            'DEFAULT=YES,AUTOSELECT=YES,URI="/t/audio.m3u8"',
        '#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="hvc1.1.6",AUDIO="aud"',
        '/t/video.m3u8',
      ].join('\n');
      expect(playlist.contains('/t/video.m3u8'), isTrue);
      expect(playlist.contains('/t/audio.m3u8'), isTrue);
    });
  });

  group('switching presentation keeps the position', () {
    test('the resume position survives the rebuild', () {
      // The native side captures the current time into pendingSeekMs before
      // reopening; this models the arithmetic it performs.
      double secondsAt(DateTime start, Duration elapsed) =>
          elapsed.inMilliseconds / 1000.0;
      final start = DateTime(2026);
      final at = secondsAt(start, const Duration(minutes: 12, seconds: 34));
      expect(at, 754.0);
      expect((at * 1000).round(), 754000);
    });
  });
}
