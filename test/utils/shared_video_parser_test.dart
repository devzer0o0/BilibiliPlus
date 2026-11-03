import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/im/type.pbenum.dart' show MsgType;
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/shared_video_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// The private-message payload is a JSON string whose shape depends on
/// `msgType`. Getting it wrong is silent - the card just never shows - so the
/// shapes are pinned here.
void main() {
  SharedVideo? parse(
    Map<String, dynamic> content, {
    int msgType = 7,
    String sender = 'StepGo',
    int senderId = 12345,
  }) =>
      SharedVideoParser.parse(
        rawContent: jsonEncode(content),
        msgType: msgType,
        senderName: sender,
        senderId: senderId,
      );

  group('a video share becomes an entry', () {
    test('share v2 with a bvid', () {
      final v = parse({
        'source': '视频',
        'bvid': 'BV1b24y1w73N',
        'title': '一个视频',
        'thumb': 'https://i0.hdslb.com/a.jpg',
      });
      expect(v, isNotNull);
      expect(v!.bvid, 'BV1b24y1w73N');
      expect(v.title, '一个视频');
      expect(v.senderName, 'StepGo');
    });

    test('an aid-only card is converted to a bvid', () {
      final v = parse({'source': '视频', 'id': 80433022, 'title': 't'});
      expect(v, isNotNull);
      expect(v!.bvid, startsWith('BV'));
      expect(v.bvid.length, greaterThan(9));
    });

    test('a missing cover is allowed', () {
      final v = parse({'bvid': 'BV1b24y1w73N', 'title': 't'});
      expect(v?.cover, '');
    });
  });

  group('non-video messages are skipped', () {
    test('a live room card', () {
      expect(parse({'source': '直播', 'room_id': 1, 'title': 't'}), isNull);
    });

    test('a dynamic card', () {
      expect(parse({'source': 'dynamic', 'id': 1, 'title': 't'}), isNull);
    });

    test('a text message', () {
      expect(
        SharedVideoParser.carriesVideo(MsgType.EN_MSG_TYPE_TEXT.value),
        isFalse,
      );
    });

    test('a picture message', () {
      expect(
        SharedVideoParser.carriesVideo(MsgType.EN_MSG_TYPE_PIC.value),
        isFalse,
      );
    });
  });

  group('malformed payloads do not throw', () {
    test('invalid JSON', () {
      expect(
        SharedVideoParser.parse(
          rawContent: 'not json',
          msgType: 7,
          senderName: 'x',
          senderId: 1,
        ),
        isNull,
      );
    });

    test('a JSON array', () {
      expect(
        SharedVideoParser.parse(
          rawContent: '[1,2,3]',
          msgType: 7,
          senderName: 'x',
          senderId: 1,
        ),
        isNull,
      );
    });

    test('a card with no id at all', () {
      expect(parse({'title': 't'}), isNull);
    });

    test('a card with no title is not worth showing', () {
      expect(parse({'bvid': 'BV1b24y1w73N'}), isNull);
    });
  });

  group('several shares sort newest first', () {
    test('the list is ordered by timestamp', () {
      final videos = [
        SharedVideoParser.parse(
          rawContent: jsonEncode({'bvid': 'BV1', 'title': 'old'}),
          msgType: 7,
          senderName: 'a',
          senderId: 1,
          timestamp: 100,
        ),
        SharedVideoParser.parse(
          rawContent: jsonEncode({'bvid': 'BV2', 'title': 'new'}),
          msgType: 7,
          senderName: 'a',
          senderId: 1,
          timestamp: 300,
        ),
      ].whereType<SharedVideo>().toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      expect(videos.first.bvid, 'BV2');
    });
  });
}
