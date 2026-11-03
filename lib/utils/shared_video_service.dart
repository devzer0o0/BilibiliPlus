import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show Session, SessionMainReply;
import 'package:PiliPlus/grpc/bilibili/im/interfaces/v1.pb.dart'
    show RspSessionMsg;
import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show Msg;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/shared_video_parser.dart';

/// Reads video shares out of the account's private messages.
///
/// Only the newest conversations are walked - the section is a convenience, not
/// an archive - and any failure yields an empty list rather than an error, so a
/// private-message problem cannot take the home feed down with it.
abstract final class SharedVideoService {
  /// Conversations to inspect. People share to threads that have other traffic,
  /// so a few are needed to find anything.
  static const int sessionsToScan = 10;

  /// Messages read per conversation, newest first.
  static const int messagesPerSession = 20;

  static Future<List<SharedVideo>> load() async {
    final sessions = await ImGrpc.sessionMain();
    if (sessions is! Success<SessionMainReply>) return const [];

    final out = <SharedVideo>[];
    // Only one-to-one conversations carry a talker uid; group and system
    // sessions have no privateId, so they are skipped rather than guessed at.
    final sessionsToVisit = sessions.response.sessions
        .where((s) => s.id.hasPrivateId() && s.id.privateId.hasTalkerUid())
        .take(sessionsToScan);
    for (final session in sessionsToVisit) {
      final loaded = await _fromSession(session);
      out.addAll(loaded);
    }

    // One video may be forwarded into several threads; keep the newest copy.
    final byBvid = <String, SharedVideo>{};
    for (final v in out) {
      final existing = byBvid[v.bvid];
      if (existing == null || v.timestamp > existing.timestamp) {
        byBvid[v.bvid] = v;
      }
    }
    final list = byBvid.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  static Future<List<SharedVideo>> _fromSession(Session session) async {
    final talkerId = session.id.privateId.talkerUid.toInt();
    if (talkerId <= 0) return const [];

    final res = await ImGrpc.syncFetchSessionMsgs(talkerId: talkerId);
    if (res is! Success<RspSessionMsg>) return const [];

    final messages = res.response.messages.take(messagesPerSession);
    final senderName = _displayName(session);
    return SharedVideoParser.parsePage(
      messages,
      senderNameOf: (_) => senderName,
      senderIdOf: (_) => talkerId,
    );
  }

  /// Falls back to the id when the account has no usable nickname, rather than
  /// showing a blank attribution.
  static String _displayName(Session session) {
    final name = session.sessionInfo.sessionName;
    if (name.trim().isNotEmpty) return name;
    return session.id.privateId.talkerUid.toString();
  }

  /// Exposed for tests: the same fold the loader uses, without the network.
  static List<SharedVideo> dedupe(Iterable<Msg> messages, {
    required String senderName,
    required int senderId,
  }) {
    final parsed = SharedVideoParser.parsePage(
      messages,
      senderNameOf: (_) => senderName,
      senderIdOf: (_) => senderId,
    );
    final byBvid = <String, SharedVideo>{};
    for (final v in parsed) {
      final existing = byBvid[v.bvid];
      if (existing == null || v.timestamp > existing.timestamp) {
        byBvid[v.bvid] = v;
      }
    }
    return byBvid.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }
}
