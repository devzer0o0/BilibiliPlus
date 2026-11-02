import 'dart:io';

import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/plugin/pl_player/utils/hdr_support.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../support/hive_test_env.dart';

/// Flutter's iOS external texture accepts only 32BGRA and the two 8-bit
/// biplanar formats (FlutterTexture.h), so a true 10-bit path is unavailable.
/// HDR is therefore gated behind the tone-mapping switch.
void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await setUpTestStorage();
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  tearDown(() => GStorage.setting.delete(SettingBoxKey.enableToneMappedHdr));

  test('the native 10-bit path stays disabled until the engine supports it', () {
    expect(HdrSupport.nativeTenBitPath, isFalse);
  });

  test('HDR qualities are blocked while the switch is off', () async {
    expect(HdrSupport.enableToneMappedHdr, isFalse);
    expect(HdrSupport.allowsHdrQuality, isFalse);
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.hdr.code), isFalse);
    expect(
      VideoUtils.isSupportedVideoQuality(VideoQuality.dolbyVision.code),
      isFalse,
    );
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.hdrVivid.code), isFalse);
  });

  test('the switch is read back from storage', () async {
    await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
    expect(HdrSupport.enableToneMappedHdr, isTrue);
  });

  test('the HDR ladder follows the gate on iOS, stays hidden elsewhere', () async {
    await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
    if (Platform.isIOS) {
      // The iOS texture path is 8-bit, so the switch is what re-exposes HDR.
      expect(HdrSupport.allowsHdrQuality, isTrue);
      expect(VideoUtils.isSupportedVideoQuality(VideoQuality.hdr.code), isTrue);
      expect(
        VideoUtils.isSupportedVideoQuality(VideoQuality.dolbyVision.code),
        isTrue,
      );
    } else {
      // The green-screen path only exists on the Darwin 8-bit texture; other
      // hosts keep the upstream ladder untouched.
      expect(HdrSupport.allowsHdrQuality, isFalse);
    }
  });

  test('SDR qualities remain selectable in both states', () async {
    for (final enabled in [false, true]) {
      await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, enabled);
      for (final q in [
        VideoQuality.super8k,
        VideoQuality.super4K,
        VideoQuality.high108060,
        VideoQuality.high1080,
        VideoQuality.clear480,
      ]) {
        expect(
          VideoUtils.isSupportedVideoQuality(q.code),
          isTrue,
          reason: '${q.desc} (switch=$enabled)',
        );
      }
      expect(VideoUtils.isSupportedVideoQuality(null), isTrue);
    }
  });

  test('the tone mapping options match what libplacebo expects', () {
    expect(HdrSupport.toneMappedPlayerOptions, {
      'tone-mapping': 'auto',
      'hdr-compute-peak': 'yes',
      'target-colorspace-hint': 'yes',
    });
  });
}