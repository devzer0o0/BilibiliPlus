import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart'
    show Session, SessionMainReply;
import 'package:PiliPlus/grpc/bilibili/im/interfaces/v1.pb.dart'
    show RspSessionMsg;
import 'package:PiliPlus/grpc/bilibili/im/type.pb.dart' show Msg;
import 'package:PiliPlus/grpc/im.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/plugin/pl_player/utils/playback_diagnostics.dart';
import 'package:PiliPlus/utils/shared_video_parser.dart';

/// Reads video shares out of the account's private messages.
///
/// Only the newest conversations are walked - the section is a convenience, not
/// an archive - and any failure yields an empty list rather than an error, so a
/// private-message problem cannot take the home feed down with it.
abstract final class SharedVideoService {
  /// Conversations to inspect. People share to threads that have other traffic,
  /// so a few are needed to find anything.
  ///
  /// This is a *budget*, not a guarantee: the section shows one specific user's
  /// shares, and that user's thread can fall out of the newest ten as other
  /// conversations become active. Scan enough that an ordinary account covers
  /// its recent history, and stop early once the wanted sender is found.
  static const int sessionsToScan = 40;

  /// Messages read per conversation, newest first.
  static const int messagesPerSession = 20;

  /// The user whose shares the home section shows: StepGo.
  static const int stepGoUid = 3546605619776050;

  static Future<List<SharedVideo>> load() async {
    final sessions = await ImGrpc.sessionMain();
    if (sessions is! Success<SessionMainReply>) {
      PlaybackDiagnostics.record('share', 'sessionMain failed: ${sessions.runtimeType}');
      return const [];
    }
    final all = sessions.response.sessions;
    PlaybackDiagnostics.record(
      'share',
      'sessions=${all.length} '
          'oneToOne=${all.where((s) => s.id.hasPrivateId() && s.id.privateId.hasTalkerUid()).length} '
          'hasStepGo=${all.any((s) => s.id.hasPrivateId() && s.id.privateId.hasTalkerUid() && s.id.privateId.talkerUid.toInt() == stepGoUid)}',
    );

    final out = <SharedVideo>[];
    // Only one-to-one conversations carry a talker uid; group and system
    // sessions have no privateId, so they are skipped rather than guessed at.
    // Read the wanted sender's own thread first: if the conversation with them
    // is present, there is no reason to walk anyone else's messages at all.
    // Scanning the newest N blindly meant the section went empty as soon as that
    // thread stopped being among the most recently active ones.
    final oneToOne = sessions.response.sessions
        .where((s) => s.id.hasPrivateId() && s.id.privateId.hasTalkerUid())
        .toList()
      ..sort((a, b) {
        final aWanted = a.id.privateId.talkerUid.toInt() == stepGoUid;
        final bWanted = b.id.privateId.talkerUid.toInt() == stepGoUid;
        if (aWanted == bWanted) return 0;
        return aWanted ? -1 : 1;
      });

    var visited = 0;
    for (final session in oneToOne) {
      if (visited >= sessionsToScan) break;
      visited++;
      final isWantedThread =
          session.id.privateId.talkerUid.toInt() == stepGoUid;
      final got = await _fromSession(session);
      PlaybackDiagnostics.record(
        'share-session',
        'talker=${session.id.privateId.talkerUid.toInt()} '
            'wanted=$isWantedThread parsed=${got.length} '
            'uids=${got.map((v) => v.senderId).toSet()}',
      );
      out.addAll(got);
      // The wanted thread was read; nothing else can contribute to its section.
      if (isWantedThread) break;
    }

    // Filter BEFORE deduplicating.
    //
    // Dedupe keeps the newest copy of each bvid. With the filter applied after
    // it, a video the wanted user shared stayed hidden whenever somebody else
    // had forwarded the same bvid later: the newer foreign copy won the dedupe,
    // then the filter removed it, and the section came up empty. Filtering the
    // sender first makes dedupe choose among that sender's copies only.
    final kept = foldForWanted(out);
    return _fillDetails(kept);
  }

  /// Replaces whatever the message body implied with the video's real title and
  /// cover.
  ///
  /// A plain-text share only carries a link, so the bvid is all that is known
  /// for certain: the surrounding prose is not the video's title and there is
  /// no cover at all. Looking each video up fixes both, and failures fall back
  /// to what the message said rather than dropping the entry.
  static Future<List<SharedVideo>> _fillDetails(List<SharedVideo> shares) async {
    if (shares.isEmpty) return shares;
    final out = <SharedVideo>[];
    for (final share in shares) {
      out.add(await _detail(share));
    }
    return out;
  }

  static Future<SharedVideo> _detail(SharedVideo share) async {
    try {
      final res = await VideoHttp.videoIntro(bvid: share.bvid);
      if (res is! Success<VideoDetailData>) {
        PlaybackDiagnostics.record(
          'share-detail',
          'bvid=${share.bvid} lookup failed ${res.runtimeType}',
        );
        return share;
      }
      final title = res.response.title;
      final pic = res.response.pic;
      final filled = share.copyWith(
        title: (title != null && title.trim().isNotEmpty) ? title.trim() : null,
        cover: (pic != null && pic.isNotEmpty) ? pic : null,
      );
      PlaybackDiagnostics.record(
        'share-detail',
        'bvid=${share.bvid} title=${filled.title} '
            'coverLen=${filled.cover.length} '
            'coverHost=${Uri.tryParse(filled.cover)?.host}',
      );
      return filled;
    } catch (_) {
      return share;
    }
  }

  /// Keeps the wanted sender's shares, one per bvid, newest first.
  ///
  /// Exposed so the ordering rule can be asserted against the production code
  /// rather than against a copy of it. Filter first, then dedupe - the reverse
  /// order is what made the section go empty.
  static List<SharedVideo> foldForWanted(Iterable<SharedVideo> shares) {
    final byBvid = <String, SharedVideo>{};
    for (final v in shares) {
      if (v.senderId != stepGoUid) continue;
      final existing = byBvid[v.bvid];
      if (existing == null || v.timestamp > existing.timestamp) {
        byBvid[v.bvid] = v;
      }
    }
    return byBvid.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  static Future<List<SharedVideo>> _fromSession(Session session) async {
    final talkerId = session.id.privateId.talkerUid.toInt();
    if (talkerId <= 0) return const [];

    final res = await ImGrpc.syncFetchSessionMsgs(talkerId: talkerId);
    if (res is! Success<RspSessionMsg>) {
      PlaybackDiagnostics.record(
        'share-session',
        'talker=$talkerId fetch failed ${res.runtimeType}',
      );
      return const [];
    }
    PlaybackDiagnostics.record(
      'share-session',
      'talker=$talkerId msgs=${res.response.messages.length}',
    );
    // Shape of what the thread actually carries: msgType, whether the content
    // parses as JSON, and whether it carries an id/title. Without this the only
    // visible symptom is "zero cards", which does not say which rule rejected
    // them.
    for (final m in res.response.messages.take(6)) {
      PlaybackDiagnostics.record(
        'share-msg',
        'type=${m.msgType} uid=${m.senderUid.toInt()} '
            'hasBvid=${RegExp(r'BV[0-9A-Za-z]{10}').hasMatch(m.content)}',
      );
    }

    final messages = res.response.messages.take(messagesPerSession);
    final sessionName = _displayName(session);
    return SharedVideoParser.parsePage(
      messages,
      // Attribute each message to whoever actually sent it. Using the talker id
      // for the whole thread credited every share in the conversation to the
      // other person, including the ones this account sent.
      senderNameOf: (m) => _senderName(session, sessionName, m),
      senderIdOf: (m) => _senderId(talkerId, m),
    );
  }

  /// The uid that sent [m], falling back to the conversation's talker when the
  /// message carries none (older payloads omit it).
  static int _senderId(int talkerId, Msg m) =>
      m.senderUid.toInt() > 0 ? m.senderUid.toInt() : talkerId;

  /// A one-to-one thread only knows the other person's name, so a message from
  /// the account itself is labelled separately instead of borrowing that name.
  static String _senderName(Session session, String sessionName, Msg m) {
    final uid = m.senderUid.toInt();
    if (uid <= 0) return sessionName;
    return uid == session.id.privateId.talkerUid.toInt() ? sessionName : '我';
  }

  /// Falls back to the id when the account has no usable nickname, rather than
  /// showing a blank attribution.
  static String _displayName(Session session) {
    final name = session.sessionInfo.sessionName;
    if (name.trim().isNotEmpty) return name;
    return session.id.privateId.talkerUid.toString();
  }

  /// The sender filter followed by the per-bvid fold, newest first.
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
