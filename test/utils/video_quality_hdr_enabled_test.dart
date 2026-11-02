import 'dart:io';

import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../support/hive_test_env.dart';

/// With the HDR tone-mapping switch on, the HDR ladder must become reachable
/// again - and must still be skipped when the switch is off.
PlayUrlModel _playUrl(List<int> ids, {String codecs = 'hev1.2.4.L153.90'}) =>
    PlayUrlModel.fromJson({
      'dash': {
        'duration': 0,
        'video': [
          for (final id in ids)
            {
              'id': id,
              'codecs': codecs,
              'width': 3840,
              'height': 2160,
            },
        ],
      },
      'accept_quality': ids,
      'support_formats': [
        for (final id in ids)
          {
            'quality': id,
            'codecs': [codecs],
          },
      ],
    });

int _pick(List<int> ids, int prefer) {
  final playUrl = _playUrl(ids);
  final dash = playUrl.dash!;
  final (quality, _, _, _) = VideoUtils.findTargetVideo(
    dash.video!,
    prefer,
    playUrl.acceptQuality,
    playUrl.supportFormats!,
    const [.AV1, .HEVC, .AVC],
  );
  return quality;
}

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

  const ladder = [125, 120, 116, 80, 64, 32, 16];

  group('tone mapping off', () {
    test('an HDR request lands on the highest SDR stream', () {
      expect(_pick(ladder, VideoQuality.hdr.code), VideoQuality.super4K.code);
    });

    test('a 4K request is not silently upgraded to HDR', () {
      expect(_pick(ladder, VideoQuality.super4K.code), VideoQuality.super4K.code);
    });

    test('a high default does not fall back to HDR', () {
      // This was the original bug: prefer >= highest used videoList.first.
      expect(_pick(ladder, VideoQuality.super8k.code), VideoQuality.super4K.code);
    });
  });

  group('tone mapping on', () {
    setUp(() async {
      await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
    });

    test('an HDR request selects the HDR stream on iOS', () {
      if (!Platform.isIOS) return;
      expect(_pick(ladder, VideoQuality.hdr.code), VideoQuality.hdr.code);
    });

    test('Dolby Vision is selectable on iOS', () {
      if (!Platform.isIOS) return;
      expect(
        _pick([126, 120, 80], VideoQuality.dolbyVision.code),
        VideoQuality.dolbyVision.code,
      );
    });

    test('a 4K request still stays on 4K, not HDR', () {
      expect(_pick(ladder, VideoQuality.super4K.code), VideoQuality.super4K.code);
    });
  });
}