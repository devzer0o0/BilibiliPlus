import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/av1_capability.dart';
import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/av1_capability_probe.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// The AV1 capability has four layers and they fail independently.
///
/// Each case here is a state the device evidence actually produced:
///
///  * the chip answers "AV1 supported" while the shipped build has no AV1
///    VideoToolbox decoder - the state that decoded 4K on the CPU for a whole
///    session while every capability check in the app said yes;
///  * the probe answers nothing at all, because a platform channel is not ready;
///  * one stream falls back to software, which says nothing about the decoder.
void main() {
  const order = <VideoDecodeFormatType>[
    VideoDecodeFormatType.AV1,
    VideoDecodeFormatType.HEVC,
    VideoDecodeFormatType.AVC,
  ];

  tearDown(() {
    VideoUtils.setAv1HardwareAvailable(null);
    Av1CapabilityProbe.invalidate();
  });

  group('capability layers', () {
    test('a fresh probe is unknown, not unsupported', () {
      final capability = Av1CapabilityProbe.capability;
      expect(capability.system, CapabilityState.unknown);
      expect(capability.mediaLibrary, CapabilityState.unknown);
      expect(capability.backend, CapabilityState.unknown);
      expect(capability.session, SessionDecodeState.idle);
    });

    test('unknown leaves AV1 in the preference order', () {
      expect(VideoUtils.av1HardwareAvailable, isTrue);
      expect(
        VideoUtils.selectCodec(['av01.0.13M.08', 'hvc1.2.4.L153.90'], order),
        VideoDecodeFormatType.AV1,
      );
    });

    test('the chip supporting AV1 does not make this build support it', () {
      // The exact conflation this replaces: system=vendor supported was read as
      // "AV1 is fine", so the stock Avcodec kept being selected.
      Av1CapabilityProbe.observeSystem(true);
      expect(Av1CapabilityProbe.capability.system, CapabilityState.supported);
      VideoUtils.setAv1HardwareAvailable(false);
      expect(
        VideoUtils.selectCodec(['av01.0.13M.08', 'hvc1.2.4.L153.90'], order),
        VideoDecodeFormatType.HEVC,
      );
    });

    test('a session that falls back to software does not rewrite the library',
        () {
      VideoUtils.setAv1HardwareAvailable(true);
      Av1CapabilityProbe.observeSession(SessionDecodeState.software);
      expect(VideoUtils.av1Capability.session, SessionDecodeState.software);
      // Still selectable: one stream is not the decoder.
      expect(VideoUtils.av1HardwareAvailable, isTrue);
      expect(
        VideoUtils.selectCodec(['av01.0.13M.08', 'hvc1.2.4.L153.90'], order),
        VideoDecodeFormatType.AV1,
      );
    });

    test('a failed probe is reported as unknown and demotes nothing', () async {
      // No binding here, so the platform channel throws; that must not become
      // "this device cannot decode AV1".
      final capability = await Av1CapabilityProbe.refresh();
      expect(capability.mediaLibrary, CapabilityState.unknown);
      expect(VideoUtils.av1HardwareAvailable, isTrue);
    });

    test('invalidating forgets the answer and bumps the generation', () {
      Av1CapabilityProbe.observeSystem(true);
      final before = Av1CapabilityProbe.generation;
      Av1CapabilityProbe.invalidate();
      expect(Av1CapabilityProbe.generation, greaterThan(before));
      expect(
        Av1CapabilityProbe.capability.system,
        CapabilityState.unknown,
      );
    });

    test('AV1 still plays when it is the only codec offered', () {
      VideoUtils.setAv1HardwareAvailable(false);
      expect(
        VideoUtils.selectCodec(['av01.0.13M.08'], order),
        VideoDecodeFormatType.AV1,
      );
    });
  });

  group('hardware decoding switch', () {
    test('off means no, never auto', () {
      // media_kit's native video controller writes `hwdec ?? 'auto'`, so a null
      // here turned "off" into "choose for me".
      final value = HwDecType.resolveHwdec(
        enable: false,
        preference: HwDecType.videotoolbox.hwdec,
      );
      expect(value, 'no');
      expect(value, isNot('auto'));
    });

    test('on passes the user preference through unchanged', () {
      expect(
        HwDecType.resolveHwdec(
          enable: true,
          preference: 'videotoolbox-copy',
        ),
        'videotoolbox-copy',
      );
    });
  });

  group('capability record', () {
    test('copyWith keeps the layers it was not asked to change', () {
      const capability = Av1Capability(
        system: CapabilityState.supported,
        mediaLibrary: CapabilityState.unsupported,
      );
      final next = capability.copyWith(session: SessionDecodeState.starting);
      expect(next.system, CapabilityState.supported);
      expect(next.mediaLibrary, CapabilityState.unsupported);
      expect(next.session, SessionDecodeState.starting);
    });

    test('only an unsupported library blocks AV1 selection', () {
      expect(
        const Av1Capability(mediaLibrary: CapabilityState.unknown)
            .canSelectAv1,
        isTrue,
      );
      expect(
        const Av1Capability(mediaLibrary: CapabilityState.supported)
            .canSelectAv1,
        isTrue,
      );
      expect(
        const Av1Capability(mediaLibrary: CapabilityState.unsupported)
            .canSelectAv1,
        isFalse,
      );
    });
  });
}
