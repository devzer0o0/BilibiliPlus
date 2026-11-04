import 'package:flutter_test/flutter_test.dart';

/// Features that only exist on the mpv path must be refused explicitly on the
/// native path.
///
/// The old code force-unwrapped `videoPlayerController`, so hitting one of
/// these with no mpv threw inside a build and left an overflow banner where the
/// player should be. Each capability is a boolean the UI can ask.
import 'package:PiliPlus/plugin/pl_player/capability.dart';

void main() {
  test('an mpv backend offers every mpv-only capability', () {
    const capabilities = PlaybackCapabilities(isMpv: true);
    expect(capabilities.shader, isTrue);
    expect(capabilities.textureScreenshot, isTrue);
    expect(capabilities.mixerVolume, isTrue);
    expect(capabilities.audioTrackSwitch, isTrue);
  });

  test('the native backend offers none of them', () {
    const capabilities = PlaybackCapabilities(isMpv: false);
    expect(capabilities.shader, isFalse);
    expect(capabilities.textureScreenshot, isFalse);
    expect(capabilities.mixerVolume, isFalse);
    expect(capabilities.audioTrackSwitch, isFalse);
  });

  test('no capability is claimed without a backend', () {
    const capabilities = PlaybackCapabilities(isMpv: false);
    expect(
      [
        capabilities.shader,
        capabilities.textureScreenshot,
        capabilities.mixerVolume,
        capabilities.audioTrackSwitch,
      ].any((v) => v),
      isFalse,
    );
  });
}
