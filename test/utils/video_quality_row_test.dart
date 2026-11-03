import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../support/hive_test_env.dart';

/// The in-player quality sheet renders one row per rung. A row must be both
/// offered by the server and renderable, otherwise tapping it would request a
/// 10-bit stream the 8-bit texture draws green.
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

  const offered = {125, 120, 116, 80, 64, 32, 16};

  group('isQualitySelectable', () {
    test('a listed SDR rung the server offered is selectable', () {
      expect(VideoUtils.isQualitySelectable(120, offered), isTrue);
      expect(VideoUtils.isQualitySelectable(80, offered), isTrue);
    });

    test('a listed HDR rung is not selectable while the gate is closed', () {
      expect(VideoUtils.isQualitySelectable(125, offered), isFalse);
    });

    test('a rung the server did not offer is not selectable', () {
      expect(VideoUtils.isQualitySelectable(127, offered), isFalse);
    });

    test('a null quality is not selectable', () {
      expect(VideoUtils.isQualitySelectable(null, offered), isFalse);
    });

    test('the HDR rung becomes selectable once the gate opens on iOS', () async {
      await GStorage.setting.put(SettingBoxKey.enableToneMappedHdr, true);
      expect(
        VideoUtils.isQualitySelectable(125, offered),
        Platform.isIOS,
      );
    });
  });

  group('qualityRowLabel', () {
    test('a renderable rung shows its own description', () {
      expect(VideoUtils.qualityRowLabel(120, '4K 超清晰', '暂不支持'), '4K 超清晰');
    });

    test('an HDR rung shows the unsupported marker', () {
      expect(VideoUtils.qualityRowLabel(125, 'HDR 真彩', '暂不支持'), '暂不支持');
    });

    test('a missing description falls back to the quality id', () {
      // This used to assert '', which is what produced visibly blank rows in
      // the quality sheet when the catalogue omitted the container string.
      final label = VideoUtils.qualityRowLabel(120, null, '暂不支持');
      expect(label, isNotEmpty);
      expect(label, contains('120'));
    });

    test('a blank description is treated as missing', () {
      expect(VideoUtils.qualityRowLabel(120, '   ', '暂不支持'), contains('120'));
    });

    test('the label and the enabled flag agree for every rung', () {
      // A row that reads "unsupported" must also be disabled, and vice versa.
      const marker = 'X';
      for (final q in offered) {
        final selectable = VideoUtils.isQualitySelectable(q, offered);
        final label = VideoUtils.qualityRowLabel(q, 'desc', marker);
        expect(
          label == marker,
          isNot(selectable),
          reason: 'rung $q: label="$label" selectable=$selectable',
        );
      }
    });
  });
}