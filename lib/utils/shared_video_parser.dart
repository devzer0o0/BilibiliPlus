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
  ///
  /// Plain text is included on purpose. Measured against this account's real
  /// conversation: the user whose shares the home section shows sends ordinary
  /// text messages with a `bilibili.com/video/BV...` link inside, not share
  /// cards. Accepting only the card types meant every one of those messages was
  /// discarded, so the section never had anything to display.
  static const shareTypes = {
    MsgType.EN_MSG_TYPE_SHARE_V2,
    MsgType.EN_MSG_TYPE_SHARE,
    MsgType.EN_MSG_TYPE_VIDEO_CARD,
    MsgType.EN_MSG_TYPE_COMMON_SHARE_CARD,
  };

  /// Types whose payload may *contain* a video link rather than being a card.
  static const textTypes = {MsgType.EN_MSG_TYPE_TEXT};

  /// `BV1xx411c7mD` as it appears in a message body or a URL.
  static final _bvidInText = RegExp(r'BV[0-9A-Za-z]{10}');

  /// The first Bilibili video link inside [text], if any.
  static SharedVideo? fromText({
    required String text,
    required String senderName,
    required int senderId,
    int timestamp = 0,
  }) {
    final match = _bvidInText.firstMatch(text);
    if (match == null) return null;
    final bvid = match.group(0)!;
    // The link sits on its own line and the title is the line ABOVE it:
    //
    //   1《让 Agent 真正看懂整个视频》Sense Now 升级
    //   https://www.bilibili.com/video/BV1tb4M6zEyD
    //
    // Using the link's own line (the first version) put a bare URL on every
    // card, which is what the strip showed.
    final lines = text.split('\n');
    var title = '';
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains(bvid)) continue;
      final own = lines[i].replaceAll(RegExp(r'https?://\S+'), '').trim();
      if (own.isNotEmpty) {
        title = own;
        break;
      }
      // Line is only the URL: take the nearest non-empty line above it.
      for (var j = i - 1; j >= 0; j--) {
        final above = _cleanTitle(lines[j]);
        if (above.isNotEmpty) {
          title = above;
          break;
        }
      }
      break;
    }
    if (title.isEmpty) title = bvid;
    if (title.length > 120) title = title.substring(0, 120);
    return SharedVideo(
      bvid: bvid,
      title: title,
      senderName: senderName,
      senderId: senderId,
      cover: '',
      timestamp: timestamp,
    );
  }

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
      SharedVideo? shared = parse(
        rawContent: m.content,
        msgType: m.msgType,
        senderName: senderNameOf(m),
        senderId: senderIdOf(m),
        timestamp: m.timestamp.toInt(),
      );
      // A card type that did not parse, or a plain message that names a video:
      // both may still carry a link in their body. This is how the digest-style
      // messages in the real conversation surface at all.
      shared ??= _fromBody(
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

  /// Extracts a video link from a message body.
  ///
  /// The payload of a text message is `{"content": "..."}`; the share text
  /// lives inside that string and may wrap several links. Anything that is not
  /// a text message, or has no link, yields null.
  static SharedVideo? _fromBody({
    required String rawContent,
    required int msgType,
    required String senderName,
    required int senderId,
    int timestamp = 0,
  }) {
    // Only plain text messages reach the body scan. A card that `parse` already
    // rejected (a live room, a dynamic, a card with no title) must stay rejected:
    // falling back for it would resurrect exactly the payloads the card rules
    // are there to exclude.
    if (!textTypes.any((t) => t.value == msgType)) return null;
    String body = rawContent;
    try {
      final decoded = jsonDecode(rawContent);
      if (decoded is Map) {
        final inner = decoded['content'];
        if (inner is String && inner.isNotEmpty) body = inner;
      }
    } catch (_) {
      // Not JSON: treat the payload itself as the text.
    }
    if (!_bvidInText.hasMatch(body)) return null;
    return fromText(
      text: body,
      senderName: senderName,
      senderId: senderId,
      timestamp: timestamp,
    );
  }

  /// Strips list numbering and the bracketed markers the digest uses, so a
  /// card shows `让 Agent 真正看懂整个视频` rather than `1《让 Agent...`. The
  /// original wording is kept - only the leading enumeration is dropped.
  static String _cleanTitle(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    // Leading `1.` / `1、` / `1 ` / `- ` used by the digest, plus the bare
    // `1《title》` form where the number runs straight into the opening bracket.
    s = s.replaceFirst(RegExp(r'^\s*(?:\d+\s*[.、)）]|[-*·])\s*'), '');
    s = s.replaceFirst(RegExp(r'^\s*\d+(?=[《【\[])'), '');
    return s.trim();
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
