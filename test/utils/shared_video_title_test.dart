import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show Msg;
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/shared_video_parser.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

/// The strip must show the video's name, not the URL that pointed at it.
///
/// The share body is a digest: a numbered line with the title, then the link on
/// its own line. Taking the link's line produced a card whose title was
/// `https://www.bilibili.com/video/BV...`.
void main() {
  const uid = 3546605619776050;

  Msg textMsg(String body, {int ts = 1000}) {
    final m = Msg()
      ..senderUid = Int64(uid)
      ..msgType = 1
      ..timestamp = Int64(ts);
    m.content = jsonEncode({'content': body});
    return m;
  }

  List<SharedVideo> parse(String body) => SharedVideoParser.parsePage(
    [textMsg(body)],
    senderNameOf: (_) => 'StepGo',
    senderIdOf: (_) => uid,
  );

  test('the title is the line above the link, not the link', () {
    final body = '今天挑了 4 条：\n\n'
        '1《让 Agent 真正看懂整个视频》Sense Now 升级\n'
        'https://www.bilibili.com/video/BV1tb4M6zEyD\n'
        '先给视频建字幕时间轴';
    final list = parse(body);
    expect(list.single.bvid, 'BV1tb4M6zEyD');
    expect(list.single.title, '《让 Agent 真正看懂整个视频》Sense Now 升级');
    expect(list.single.title, isNot(contains('http')));
  });

  test('leading list numbering is dropped from the title', () {
    final body = '今天有 4 条：\n\n'
        '1. 《记忆插件装上之后》\n'
        'https://www.bilibili.com/video/BV1Cw4G6CEGX';
    expect(parse(body).single.title, '《记忆插件装上之后》');
  });

  test('a link alone never yields a URL as the title', () {
    final body = '看这个\n\nhttps://www.bilibili.com/video/BV1xx411c7mD';
    expect(parse(body).single.title, isNot(contains('http')));
  });

  test('blank lines above the link are skipped', () {
    final body = '标题在这里\n\n\n\nhttps://www.bilibili.com/video/BV1xx411c7mD';
    expect(parse(body).single.title, '标题在这里');
  });

  test('the cover starts empty and is filled later by lookup', () {
    final body = '标题\nhttps://www.bilibili.com/video/BV1tb4M6zEyD';
    final v = parse(body).single;
    expect(v.cover, isEmpty);
    final filled = v.copyWith(title: '真实标题', cover: 'https://i0.hdslb.com/x.jpg');
    expect(filled.title, '真实标题');
    expect(filled.cover, 'https://i0.hdslb.com/x.jpg');
    expect(filled.bvid, v.bvid);
  });
}
