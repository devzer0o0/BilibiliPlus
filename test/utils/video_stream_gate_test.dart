import 'dart:io';

import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../support/hive_test_env.dart';

/// The id blocklist only knows today's rungs. Checking the codec profile
/// catches a future 10-bit rung whose id is not listed yet.
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

  group('isTenBitCodec', () {
    test('HEVC Main10 profiles are 10-bit', () {
      expect(VideoUtils.isTenBitCodec('hvc1.2.4.L153.90'), isTrue);
      expect(VideoUtils.isTenBitCodec('hev1.2.4.L153.90'), isTrue);
    });

    test('HEVC Main is 8-bit', () {
      expect(VideoUtils.isTenBitCodec('hvc1.1.6.L153.90'), isFalse);
      expect(VideoUtils.isTenBitCodec('hvc1.1.6.L150.90'), isFalse);
    });

    test('AV1 bit depth comes from the fourth field', () {
      expect(VideoUtils.isTenBitCodec('av01.0.12M.10.0.110.01.01.01.0'), isTrue);
      expect(VideoUtils.isTenBitCodec('av01.0.12M.08.0.110.01.01.01.0'), isFalse);
    });

    test('AVC is never 10-bit', () {
      expect(VideoUtils.isTenBitCodec('avc1.640033'), isFalse);
      expect(VideoUtils.isTenBitCodec('avc1.640028'), isFalse);
    });

    test('null and empty are not 10-bit', () {
      expect(VideoUtils.isTenBitCodec(null), isFalse);
      expect(VideoUtils.isTenBitCodec(''), isFalse);
    });
  });

  group('isSupportedVideoStream', () {
    test('an unlisted id carrying Main10 is still rejected', () async {
      // This is the case the id blocklist alone misses.
      expect(
        VideoUtils.isSupportedVideoStream(130, 'hvc1.2.4.L153.90'),
        isFalse,
      );
    });

    test('an unlisted id carrying Main is allowed', () async {
      expect(
        VideoUtils.isSupportedVideoStream(122, 'hvc1.1.6.L153.90'),
        isTrue,
      );
    });

    test('a listed SDR id with an 8-bit codec is allowed', () async {
      expect(
        VideoUtils.isSupportedVideoStream(120, 'hvc1.1.6.L153.90'),
        isTrue,
      );
    });

    test('an unlisted id stays rejected no matter the codec', () async {
      // isSupportedVideoQuality runs first, so opening the gate does not make an
      // arbitrary id acceptable - only the known HDR rungs become selectable.
      await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
      expect(
        VideoUtils.isSupportedVideoStream(130, 'hvc1.2.4.L153.90'),
        isFalse,
      );
    });

    test('a known HDR rung follows the gate, which is iOS-only', () async {
      await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
      // HdrSupport.allowsHdrQuality is false off iOS, so the 10-bit stream stays
      // rejected there even with the switch on. Assert both branches so this
      // test is meaningful on whichever host runs it.
      expect(
        VideoUtils.isSupportedVideoStream(125, 'hvc1.2.4.L153.90'),
        Platform.isIOS,
      );
    });
  });

  group('selectVideoVariant', () {
    VideoItem item(int id, String codecs) => VideoItem.fromJson({
      'id': id,
      'codecs': codecs,
      'width': 3840,
      'height': 2160,
    }, null);

    test('prefers the requested codec among usable variants', () {
      final variants = [
        item(122, 'hvc1.1.6.L153.90'),
        item(122, 'avc1.640033'),
      ];
      final picked = VideoUtils.selectVideoVariant(
        variants,
        VideoDecodeFormatType.AVC,
        allowTenBit: false,
      );
      expect(picked.codecs, 'avc1.640033');
    });

    test('skips a 10-bit variant when they are not allowed', () {
      final variants = [
        item(130, 'hvc1.2.4.L153.90'),
        item(130, 'avc1.640033'),
      ];
      final picked = VideoUtils.selectVideoVariant(
        variants,
        VideoDecodeFormatType.HEVC,
        allowTenBit: false,
      );
      // HEVC was requested but only the 10-bit HEVC exists, so the 8-bit AVC
      // entry must win over the first-listed one.
      expect(picked.codecs, 'avc1.640033');
    });

    test('takes the 10-bit variant when allowed', () {
      final variants = [item(130, 'hvc1.2.4.L153.90')];
      final picked = VideoUtils.selectVideoVariant(
        variants,
        VideoDecodeFormatType.HEVC,
        allowTenBit: true,
      );
      expect(picked.codecs, 'hvc1.2.4.L153.90');
    });

    test('falls back to the first entry when nothing is usable', () {
      final variants = [item(130, 'hvc1.2.4.L153.90')];
      final picked = VideoUtils.selectVideoVariant(
        variants,
        VideoDecodeFormatType.AVC,
        allowTenBit: false,
      );
      // Nothing renderable exists; better to return something than crash.
      expect(picked.id, 130);
    });
  });
}