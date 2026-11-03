import 'dart:io';

import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/shared_video_read_store.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../support/hive_test_env.dart';

SharedVideo video(String bvid) => SharedVideo(
  bvid: bvid,
  title: 't',
  senderName: 'StepGo',
  senderId: 1,
  cover: '',
);

/// A shared video stays on the home feed until the user opens it. That rule is
/// the whole point of the feature, so it is asserted rather than assumed.
void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await setUpTestStorage();
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  tearDown(() => GStorage.setting.delete(SettingBoxKey.openedSharedVideos));

  group('nothing is filtered until something is opened', () {
    test('an empty store keeps every share', () {
      final all = [video('BV1'), video('BV2')];
      expect(SharedVideoReadStore.visible(all).map((e) => e.bvid), ['BV1', 'BV2']);
    });

    test('hasOpened is false for an unknown bvid', () {
      expect(SharedVideoReadStore.hasOpened('BV9'), isFalse);
    });
  });

  group('opening a share hides exactly that share', () {
    test('the opened bvid disappears, the rest stay', () async {
      await SharedVideoReadStore.markOpened('BV1');
      final visible = SharedVideoReadStore.visible([video('BV1'), video('BV2')]);
      expect(visible.map((e) => e.bvid), ['BV2']);
    });

    test('an unrelated bvid is unaffected', () async {
      await SharedVideoReadStore.markOpened('BV1');
      expect(SharedVideoReadStore.hasOpened('BV2'), isFalse);
    });

    test('the order of the remaining shares is preserved', () async {
      await SharedVideoReadStore.markOpened('BV2');
      final visible = SharedVideoReadStore.visible([
        video('BV1'),
        video('BV2'),
        video('BV3'),
      ]);
      expect(visible.map((e) => e.bvid), ['BV1', 'BV3']);
    });
  });

  group('the store stays bounded', () {
    test('marking the same bvid twice does not duplicate it', () async {
      await SharedVideoReadStore.markOpened('BV1');
      await SharedVideoReadStore.markOpened('BV1');
      expect(
        SharedVideoReadStore.opened.where((e) => e == 'BV1').length,
        1,
      );
    });

    test('only the newest maxRemembered ids are kept', () async {
      for (var i = 0; i < SharedVideoReadStore.maxRemembered + 20; i++) {
        await SharedVideoReadStore.markOpened('BVK$i');
      }
      expect(
        SharedVideoReadStore.opened.length,
        SharedVideoReadStore.maxRemembered,
      );
      // The newest survives, the oldest is dropped.
      expect(SharedVideoReadStore.hasOpened('BVK${SharedVideoReadStore.maxRemembered + 19}'), isTrue);
      expect(SharedVideoReadStore.hasOpened('BVK0'), isFalse);
    });
  });

  group('a share can be brought back', () {
    test('markUnopened restores it', () async {
      await SharedVideoReadStore.markOpened('BV1');
      await SharedVideoReadStore.markUnopened('BV1');
      expect(SharedVideoReadStore.hasOpened('BV1'), isFalse);
      expect(
        SharedVideoReadStore.visible([video('BV1')]).map((e) => e.bvid),
        ['BV1'],
      );
    });
  });
}
