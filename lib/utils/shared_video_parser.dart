import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show Msg, MsgType;
import 'package:PiliPlus/models/common/msg/shared_video.dart';

/// Turns private-message payloads into [SharedVideo]s.
///
/// Kept free of network and Hive so the parsing rules can be asserted directly:
/// the payload is a JSON string whose shape differs per `msgType`, and getting
/// it wrong is silent (the card simply never appears).
abstract final class SharedVideoParser {
  /// Message types that can carry a shared video.
  static const shareTypes = {
    MsgType.EN_MSG_TYPE_SHARE_V2,
    MsgType.EN_MSG_TYPE_SHARE,
    MsgType.EN_MSG_TYPE_VIDEO_CARD,
    MsgType.EN_MSG_TYPE_COMMON_SHARE_CARD,
  };

  static bool carriesVideo(int msgType) =>
      shareTypes.any((t) => t.value == msgType);

  /// Returns null when the message is not a video share, or the payload cannot
  /// be read - a malformed card must not take the whole feed down.
  static SharedVideo? parse({
    required String rawContent,
    required int msgType,
    required String senderName,
    required int senderId,
    int timestamp = 0,
  }) {
    if (!carriesVideo(msgType)) return null;

    Map<String, dynamic> content;
    try {
      final decoded = jsonDecode(rawContent);
      if (decoded is! Map) return null;
      content = decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }

    // A live room and a dynamic sit in the same envelope as a video; the
    // `source`/`type` pair is what separates them.
    final source = (content['source'] ?? content['type'] ?? '').toString();
    if (source == '直播' || source == 'dynamic') return null;

    String? bvid = _str(content['bvid']);
    final aidRaw = content['id'] ?? content['aid'];
    final aid = aidRaw is int ? aidRaw : int.tryParse(aidRaw?.toString() ?? '');

    if (bvid == null || bvid.isEmpty) {
      if (aid == null) return null;
      bvid = _avToBv(aid);
      if (bvid == null) return null;
    }

    // Republishes and plain-text forwards carry the id but no card body; without
    // a title there is nothing worth putting on the feed.
    final title = _str(content['title']) ?? _str(content['desc']);
    if (title == null || title.trim().isEmpty) return null;

    return SharedVideo(
      bvid: bvid,
      title: title.trim(),
      senderName: senderName,
      senderId: senderId,
      cover: _str(content['thumb']) ?? _str(content['cover']) ?? '',
      timestamp: timestamp,
    );
  }

  /// Walks a page of messages and keeps the video shares, newest first.
  static List<SharedVideo> parsePage(
    Iterable<Msg> messages, {
    required String Function(Msg) senderNameOf,
    required int Function(Msg) senderIdOf,
  }) {
    final out = <SharedVideo>[];
    for (final m in messages) {
      final shared = parse(
        rawContent: m.content,
        msgType: m.msgType,
        senderName: senderNameOf(m),
        senderId: senderIdOf(m),
        timestamp: m.timestamp.toInt(),
      );
      if (shared != null) out.add(shared);
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  static String? _str(Object? v) => v is String ? v : null;

  /// Minimal aid -> bvid, so a card that only carries an aid still works.
  ///
  /// Mirrors `IdUtils.av2bv`; duplicated rather than imported so this file stays
  /// dependency-light and testable without the app's service locator.
  static String? _avToBv(int aid) {
    if (aid <= 0) return null;
    const table = 'fZodR9XQDSUm21yCkr6zBqiveYah8bt4xsWpHnJE7jL5VG3guMTKNPAwcF';
    const xors = [177451812, 8728348608];
    const positions = [11, 10, 3, 8, 4, 6];
    var x = (aid ^ xors[0]) + xors[1];
    final chars = 'BV1  4 1 7  '.split('');
    for (var i = 0; i < 6; i++) {
      chars[positions[i]] = table[(x ~/ _pow(58, i)) % 58];
    }
    return chars.join();
  }

  static int _pow(int base, int exp) {
    var r = 1;
    for (var i = 0; i < exp; i++) {
      r *= base;
    }
    return r;
  }
}
