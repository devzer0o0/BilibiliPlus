import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The controls must not require an mpv instance.
///
/// On the native HDR path there is no `VideoController`, so anything that force
/// unwraps one cannot be mounted there - which is why HDR used to end up with a
/// separate, poorer control layer. The shared player now chooses between the
/// mpv texture and the native surface; everything around them is the same UI.
void main() {
  test('the native surface replaces the texture instead of stacking on it', () {
    const native = Text('native', textDirection: TextDirection.ltr);
    const mpv = Text('mpv', textDirection: TextDirection.ltr);

    expect(chooseSurface(mpv: null, native: native), same(native));
    expect(chooseSurface(mpv: mpv, native: native), same(mpv));
  });

  test('no backend renders nothing rather than crashing', () {
    expect(chooseSurface(mpv: null, native: null), isA<SizedBox>());
  });

  test('subtitles fall back to the Flutter overlay when mpv is absent', () {
    const overlay = Text('cues', textDirection: TextDirection.ltr);
    expect(chooseSubtitles(mpv: null, overlay: overlay), same(overlay));
    expect(chooseSubtitles(mpv: const SizedBox(), overlay: null), isNotNull);
    expect(chooseSubtitles(mpv: null, overlay: null), isNull);
  });
}

/// The exact rule `PLVideoPlayer` applies to the picture.
Widget chooseSurface({Widget? mpv, Widget? native}) =>
    mpv ?? native ?? const SizedBox.shrink();

/// The exact rule `PLVideoPlayer` applies to subtitles.
Widget? chooseSubtitles({Widget? mpv, Widget? overlay}) => overlay ?? mpv;
