import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/home_feed_policy.dart';
import 'package:flutter_test/flutter_test.dart';

SharedVideo video(String bvid) => SharedVideo(
  bvid: bvid,
  title: 't',
  senderName: 'StepGo',
  senderId: 1,
  cover: '',
);

void main() {
  group('the grid wants six', () {
    test('fewer than six triggers a top-up', () {
      expect(
        HomeFeedPolicy.needsMore(currentLength: 4, fetchedPages: 0, atEnd: false),
        isTrue,
      );
    });

    test('six is enough', () {
      expect(
        HomeFeedPolicy.needsMore(currentLength: 6, fetchedPages: 0, atEnd: false),
        isFalse,
      );
    });

    test('more than six is also enough', () {
      expect(
        HomeFeedPolicy.needsMore(currentLength: 9, fetchedPages: 0, atEnd: false),
        isFalse,
      );
    });
  });

  group('the top-up is bounded', () {
    test('it stops after maxTopUpPages', () {
      expect(
        HomeFeedPolicy.needsMore(
          currentLength: 2,
          fetchedPages: HomeFeedPolicy.maxTopUpPages,
          atEnd: false,
        ),
        isFalse,
      );
    });

    test('the last allowed page still runs', () {
      expect(
        HomeFeedPolicy.needsMore(
          currentLength: 2,
          fetchedPages: HomeFeedPolicy.maxTopUpPages - 1,
          atEnd: false,
        ),
        isTrue,
      );
    });

    test('end of feed stops it even when short', () {
      // Otherwise a feed with no more pages would retry on every refresh.
      expect(
        HomeFeedPolicy.needsMore(currentLength: 1, fetchedPages: 0, atEnd: true),
        isFalse,
      );
    });
  });

  group('the grid holds exactly six', () {
    test('truncates a longer list', () {
      final items = List.generate(10, (i) => 'v$i');
      expect(HomeFeedPolicy.grid(items).length, 6);
      expect(HomeFeedPolicy.grid(items).first, 'v0');
    });

    test('keeps a shorter list as-is', () {
      final items = List.generate(3, (i) => 'v$i');
      expect(HomeFeedPolicy.grid(items).length, 3);
    });
  });

  group('shared videos are separate from the six', () {
    test('opened shares are removed', () {
      final all = [video('BV1'), video('BV2')];
      final visible = HomeFeedPolicy.sharedSection(all, {'BV1'});
      expect(visible.map((e) => e.bvid), ['BV2']);
    });

    test('an empty opened set keeps everything', () {
      final all = [video('BV1'), video('BV2')];
      expect(HomeFeedPolicy.sharedSection(all, {}).length, 2);
    });

    test('the shared count never affects the grid count', () {
      // Three shares plus a short grid must still top the grid up to six.
      final shares = HomeFeedPolicy.sharedSection(
        [video('BV1'), video('BV2'), video('BV3')],
        {},
      );
      expect(shares.length, 3);
      expect(
        HomeFeedPolicy.needsMore(
          currentLength: 4,
          fetchedPages: 0,
          atEnd: false,
        ),
        isTrue,
      );
    });
  });
}
