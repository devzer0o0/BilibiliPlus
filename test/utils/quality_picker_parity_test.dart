import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../support/hive_test_env.dart';

/// There are two quality pickers in the player: the sheet reached from the top
/// bar, and a `BottomControlType.qa` popup in the control bar. Both persist the
/// choice as the default, so both must use the same predicate - the popup
/// originally only checked whether the server offered the rung.
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

  // Ladder as the server returns it for a title that has every rung.
  const ladder = {129, 126, 125, 120, 116, 80, 64, 32, 16};

  group('both pickers must agree on what is selectable', () {
    test('server-offered is not sufficient for HDR', () {
      // The old popup condition was exactly this, and it let HDR through.
      for (final hdr in [129, 126, 125]) {
        expect(ladder.contains(hdr), isTrue);
        expect(VideoUtils.isQualitySelectable(hdr, ladder), isFalse);
      }
    });

    test('SDR rungs the server offered stay selectable', () {
      for (final q in [120, 116, 80, 64, 32, 16]) {
        expect(VideoUtils.isQualitySelectable(q, ladder), isTrue, reason: '$q');
      }
    });

    test('a rung absent from the ladder is not selectable', () {
      expect(VideoUtils.isQualitySelectable(127, ladder), isFalse);
    });
  });

  group('the popup label matches the enabled state', () {
    test('a disabled rung reads as unsupported', () {
      // The popup dims the text when disabled; both derive from the same call.
      const marker = 'X';
      for (final q in ladder) {
        final selectable = VideoUtils.isQualitySelectable(q, ladder);
        final label = VideoUtils.qualityRowLabel(q, 'desc', marker);
        expect(label == marker, isNot(selectable), reason: 'rung $q');
      }
    });
  });

  group('opening the gate makes HDR selectable in both pickers', () {
    test('all three HDR rungs become available on iOS', () async {
      await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
      for (final hdr in [129, 126, 125]) {
        expect(
          VideoUtils.isQualitySelectable(hdr, ladder),
          Platform.isIOS,
          reason: 'rung $hdr',
        );
      }
    });
  });
}