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

/// The gate has to hold for every rung of the ladder, not just Dolby Vision.
/// These cases mirror what the simulator reported through the QA_PICK log
/// line for BV1b24y1w73N and BV1Hbs96JEM3.
PlayUrlModel _playUrl(List<int> ids, {String codecs = 'hvc1.2.4.L153.90'}) =>
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

  // A ladder with both HDR rungs present, as the server returns it.
  const hdrLadder = [125, 120, 116, 80, 64, 32, 16];

  group('gate closed', () {
    test('an HDR Vivid request degrades to 4K', () {
      expect(_pick(hdrLadder, 125), 120);
    });

    test('a Dolby Vision request degrades to 4K', () {
      expect(_pick(hdrLadder, 126), 120);
    });

    test('4K is served as-is', () {
      expect(_pick(hdrLadder, 120), 120);
    });

    test('1080P is served as-is', () {
      expect(_pick(hdrLadder, 80), 80);
    });
  });

  group('gate open on iOS', () {
    setUp(() async {
      await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
    });

    test('HDR Vivid is reachable', () {
      if (!Platform.isIOS) return;
      expect(_pick(hdrLadder, 125), 125);
    });

    test('Dolby Vision is reachable', () {
      if (!Platform.isIOS) return;
      expect(_pick([126, 112, 80, 64], 126), 126);
    });

    test('4K still does not drift up to HDR', () {
      expect(_pick(hdrLadder, 120), 120);
    });
  });

  group('unknown rungs', () {
    test('a quality the server did not return degrades safely', () {
      // 125 requested, but the server only offered 112/80/64.
      expect(_pick([112, 80, 64], 125), 112);
    });

    test('120 requested against a Dolby-only ladder degrades safely', () {
      expect(_pick([126, 112, 80], 120), 112);
    });
  });
}