import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../support/hive_test_env.dart';

/// Choosing a quality in the player writes it back as the default. That write
/// is what makes a bad choice sticky across every later video, so the write
/// must be gated the same way the row is.
void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await setUpTestStorage();
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  tearDown(() async {
    await GStorage.setting.delete(SettingBoxKey.enableToneMappedHdr);
    await GStorage.setting.delete(SettingBoxKey.defaultVideoQa);
    await GStorage.setting.delete(SettingBoxKey.defaultVideoQaCellular);
  });

  const offered = {125, 120, 116, 80, 64, 32, 16};

  group('the persisted default is only ever a renderable rung', () {
    test('the guard rejects HDR the row would have hidden', () {
      // This mirrors the re-check added to the ListTile onTap: if it returns
      // true the handler proceeds and writes the value to the setting box.
      expect(VideoUtils.isQualitySelectable(125, offered), isFalse);
      expect(VideoUtils.isQualitySelectable(120, offered), isTrue);
    });

    test('a rung the server never offered is not persisted either', () {
      expect(VideoUtils.isQualitySelectable(127, offered), isFalse);
    });

    test('every rung the guard accepts survives the bit-depth check', () {
      // Belt and braces: a row that passes isQualitySelectable must also be
      // acceptable to isSupportedVideoStream with a typical HEVC codec.
      for (final q in offered) {
        if (!VideoUtils.isQualitySelectable(q, offered)) continue;
        final tenBit = q == 125 || q == 129 || q == 126;
        expect(
          VideoUtils.isSupportedVideoStream(
            q,
            tenBit ? 'hvc1.2.4.L153.90' : 'hvc1.1.6.L153.90',
          ),
          isTrue,
          reason: 'rung $q',
        );
      }
    });
  });

  group('the setting box round-trips a chosen rung', () {
    test('writing and reading a quality keeps its value', () async {
      await GStorage.setting.put(SettingBoxKey.defaultVideoQa, 120);
      expect(GStorage.setting.get(SettingBoxKey.defaultVideoQa), 120);
    });

    test('both the wifi and cellular slots are independent', () async {
      await GStorage.setting.put(SettingBoxKey.defaultVideoQa, 120);
      await GStorage.setting.put(SettingBoxKey.defaultVideoQaCellular, 80);
      expect(GStorage.setting.get(SettingBoxKey.defaultVideoQa), 120);
      expect(GStorage.setting.get(SettingBoxKey.defaultVideoQaCellular), 80);
    });
  });
}