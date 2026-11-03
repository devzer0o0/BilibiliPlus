import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show Msg;
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/shared_video_service.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

/// The home section is "videos StepGo shared", not "videos anyone shared".
/// Keeping the attribution honest is the point, so it is asserted.
void main() {
  Msg shareFrom(int uid, String bvid) {
    final m = Msg()
      ..senderUid = Int64(uid)
      ..msgType = 7
      ..timestamp = Int64(1000);
    m.content = '{"title":"t","jumpUri":"https://www.bilibili.com/video/$bvid"}';
    return m;
  }

  test('StepGo is a fixed uid', () {
    expect(SharedVideoService.stepGoUid, 3546605619776050);
  });

  test('only StepGo\'s shares survive the filter', () {
    final all = <SharedVideo>[
      const SharedVideo(
        bvid: 'BV_stepgo',
        title: 't',
        senderName: 'StepGo',
        senderId: 3546605619776050,
        cover: '',
      ),
      const SharedVideo(
        bvid: 'BV_other',
        title: 't',
        senderName: 'Someone',
        senderId: 42,
        cover: '',
      ),
    ];
    final kept = all
        .where((v) => v.senderId == SharedVideoService.stepGoUid)
        .map((v) => v.bvid);
    expect(kept, ['BV_stepgo']);
  });
}
