import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/shared_video_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The section shows one specific user's shares, so the order of the two
/// transforms inside the loader matters.
///
/// Regression pinned here: the filter used to run *after* deduplication. Dedupe
/// keeps the newest copy of each bvid, so when somebody else forwarded the same
/// video later, the newer foreign copy won, the filter then removed it, and the
/// section came up empty even though the wanted user had shared it.
void main() {
  const stepgo = SharedVideoService.stepGoUid;

  SharedVideo share(String bvid, int uid, int ts) => SharedVideo(
    bvid: bvid,
    title: 't',
    senderName: uid == stepgo ? 'StepGo' : 'Someone',
    senderId: uid,
    cover: '',
    timestamp: ts,
  );

  group('someone else forwarding the same video does not hide it', () {
    test('a newer foreign copy no longer wins and then removes the entry', () {
      final merged = SharedVideoService.foldForWanted([
        share('BV1x', stepgo, 1000),
        share('BV1x', 42, 2000),
      ]);
      expect(merged.map((v) => v.bvid), ['BV1x']);
      expect(merged.single.senderId, stepgo);
      expect(merged.single.timestamp, 1000);
    });

    test('the newest copy among the wanted sender wins', () {
      final merged = SharedVideoService.foldForWanted([
        share('BV1x', stepgo, 1000),
        share('BV1x', stepgo, 3000),
      ]);
      expect(merged.single.timestamp, 3000);
    });
  });

  group('other senders are still excluded', () {
    test('a foreign share alone yields nothing', () {
      final merged = SharedVideoService.foldForWanted([share('BV1y', 42, 1000)]);
      expect(merged, isEmpty);
    });

    test('mixed input keeps only the wanted sender', () {
      final merged = SharedVideoService.foldForWanted([
        share('BV1a', stepgo, 1000),
        share('BV1b', 42, 2000),
        share('BV1c', stepgo, 3000),
      ]);
      expect(merged.map((v) => v.bvid), ['BV1c', 'BV1a']);
    });
  });

  test('the result is newest first', () {
    final merged = SharedVideoService.foldForWanted([
      share('BV_old', stepgo, 100),
      share('BV_new', stepgo, 900),
      share('BV_mid', stepgo, 500),
    ]);
    expect(merged.map((v) => v.bvid), ['BV_new', 'BV_mid', 'BV_old']);
  });
}
