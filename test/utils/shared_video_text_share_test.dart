import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show Msg;
import 'package:PiliPlus/utils/shared_video_parser.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real conversation shape, not a synthetic card.
///
/// Measured on the actual account: the user whose shares the home section shows
/// sends **plain text** messages (`EN_MSG_TYPE_TEXT`) whose body is a digest with
/// a `bilibili.com/video/BV...` link inside. The parser accepted only share card
/// types, so all twelve messages in that thread produced zero entries and the
/// section stayed empty.
void main() {
  const uid = 3546605619776050;

  Msg textMsg(String body, {int ts = 1000}) {
    final m = Msg()
      ..senderUid = Int64(uid)
      ..msgType = 1 // EN_MSG_TYPE_TEXT
      ..timestamp = Int64(ts);
    // The real payload wraps the body in a JSON object.
    m.content = jsonEncode({'content': body});
    return m;
  }

  test('a text message with a video link yields a share', () {
    final body = '今天挑了 4 条：\n\n1《让 Agent 真正看懂整个视频》Sense Now 升级\n'
        'https://www.bilibili.com/video/BV1tb4M6zEyD\n先给视频建字幕时间轴';
    final list = SharedVideoParser.parsePage(
      [textMsg(body)],
      senderNameOf: (_) => 'StepGo',
      senderIdOf: (_) => uid,
    );
    expect(list, hasLength(1));
    expect(list.single.bvid, 'BV1tb4M6zEyD');
    expect(list.single.senderId, uid);
    // The title is the line above the link; the link itself must not leak in.
    expect(list.single.title, '《让 Agent 真正看懂整个视频》Sense Now 升级');
  });

  test('a text message without a link yields nothing', () {
    final list = SharedVideoParser.parsePage(
      [textMsg('今天没有视频，随便聊聊')],
      senderNameOf: (_) => 'StepGo',
      senderIdOf: (_) => uid,
    );
    expect(list, isEmpty);
  });

  test('the title comes from the line carrying the link', () {
    final body = '今天翻到几条：\n\n1《记忆插件装上之后》\n'
        'https://www.bilibili.com/video/BV1Cw4G6CEGX\n记忆插件救不了规矩';
    final list = SharedVideoParser.parsePage(
      [textMsg(body)],
      senderNameOf: (_) => 'StepGo',
      senderIdOf: (_) => uid,
    );
    expect(list.single.bvid, 'BV1Cw4G6CEGX');
    expect(list.single.title, '《记忆插件装上之后》');
    expect(list.single.title, isNot(contains('http')));
  });

  test('share cards still parse as before', () {
    final m = Msg()
      ..senderUid = Int64(uid)
      ..msgType = 7
      ..timestamp = Int64(2000);
    m.content = jsonEncode({
      'title': '卡片标题',
      'bvid': 'BV1xx411c7mD',
      'thumb': 'https://i0.hdslb.com/a.jpg',
    });
    final list = SharedVideoParser.parsePage(
      [m],
      senderNameOf: (_) => 'StepGo',
      senderIdOf: (_) => uid,
    );
    expect(list, hasLength(1));
    expect(list.single.bvid, 'BV1xx411c7mD');
    expect(list.single.title, '卡片标题');
  });

  test('a live or dynamic card is still refused', () {
    final m = Msg()
      ..senderUid = Int64(uid)
      ..msgType = 7
      ..timestamp = Int64(3000);
    m.content = jsonEncode({'source': '直播', 'title': '直播中', 'bvid': 'BV1xx411c7mD'});
    final list = SharedVideoParser.parsePage(
      [m],
      senderNameOf: (_) => 'StepGo',
      senderIdOf: (_) => uid,
    );
    expect(list, isEmpty);
  });
}
