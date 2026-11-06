import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/models/model_video.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/parse_int.dart';
import 'package:PiliPlus/utils/parse_string.dart';

class RcmdVideoItemAppModel extends BaseRcmdVideoItemModel {
  int? get id => aid;

  /// The publish time, in Unix seconds, under any of the keys this feed has
  /// been seen to use. Returns null when the payload carries none, which the
  /// age filter treats as "keep" rather than "drop".
  static int? _pubdateOf(Map<String, dynamic> json) {
    for (final key in const ['pubdate', 'pub_time', 'pubtime', 'ctime']) {
      final raw = json[key] ?? json['player_args']?[key];
      if (raw is int) return raw;
      if (raw is String) {
        final parsed = int.tryParse(raw);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  String? talkBack;

  String? cardType;
  ThreePoint? threePoint;

  RcmdVideoItemAppModel.fromJson(Map<String, dynamic> json) {
    aid = json['player_args']?['aid'] ?? parseIntOrNull(json['param']);
    bvid = json['bvid'] ?? IdUtils.av2bv(aid!);
    cid = json['player_args']?['cid'];
    cover = json['cover'];
    stat = RcmdStat.fromJson(json);
    // 改用player_args中的duration作为原始数据（秒数）
    duration = json['player_args']?['duration'] ?? 0;
    //duration = json['cover_right_text'];
    title = json['title'];
    goto = json['card_goto'];
    owner = RcmdOwner.fromJson(json, goto);
    rcmdReason = json['rcmd_reason'];
    if (rcmdReason == '竖屏') rcmdReason = null;
    // The app feed is not documented and has used several spellings for the
    // publish time. Without one of them `pubdate` stayed null for every card,
    // which the age filter reads as "undated" and keeps - i.e. the setting
    // would have looked enabled and done nothing.
    pubdate = _pubdateOf(json);
    //     json['bottom_rcmd_reason'] ??
    //     json['top_rcmd_reason'];
    if (rcmdReason != null && rcmdReason!.contains('赞')) {
      // 有时能在推荐原因里获得点赞数
      (stat as RcmdStat).like = NumUtils.parseNum(rcmdReason!);
    }
    // 由于app端api并不会直接返回与owner的关注状态
    // 所以借用推荐原因是否为“已关注”、“新关注”判别关注状态，从而与web端接口等效
    isFollowed = const {'已关注', '新关注'}.contains(rcmdReason);
    // 如果是，就无需再显示推荐原因，交由view统一处理即可
    if (isFollowed) rcmdReason = null;

    param = int.parse(json['param']);
    uri = json['uri'];
    talkBack = json['talk_back'];

    if (goto == 'bangumi') {
      pgcBadge = json['cover_right_text'];
    }

    cardType = json['card_type'];
    threePoint = json['three_point_v2'] != null
        ? ThreePoint.fromJson(json['three_point_v2'])
        : null;
    desc = json['desc'];
  }

  /// Rebuilds a card from the home feed cache. Only display fields survive;
  /// the cached card never claims to be fresher than the feed item it came
  /// from, so a missing value stays null.
  RcmdVideoItemAppModel.fromCacheJson(Map<String, dynamic> json) {
    title = json['title'] as String? ?? '';
    bvid = json['bvid'] as String?;
    cid = safeToInt(json['cid']);
    aid = safeToInt(json['aid']);
    goto = json['goto'] as String?;
    uri = json['uri'] as String?;
    cover = json['cover'] as String?;
    duration = safeToInt(json['duration']) ?? -1;
    pubdate = safeToInt(json['pubdate']);
    desc = json['desc'] as String?;
    rcmdReason = json['rcmdReason'] as String?;
    isFollowed = json['isFollowed'] == true;
    param = safeToInt(json['param']);
    pgcBadge = json['pgcBadge'] as String?;
    owner = Owner(
      mid: safeToInt(json['ownerMid']),
      name: json['ownerName'] as String?,
    );
    stat = Stat.fromJson({
      'view': json['view'],
      'like': json['like'],
      'danmaku': json['danmu'],
    });
    talkBack = json['talkBack'] as String?;
    cardType = json['cardType'] as String?;
    threePoint = switch (json['threePoint']) {
      final Map raw => ThreePoint.fromCacheJson(raw.cast<String, dynamic>()),
      _ => null,
    };
  }

  @override
  Map<String, dynamic> toCacheJson() => {
    'kind': 'app',
    'title': title,
    'bvid': bvid,
    'cid': cid,
    'aid': aid,
    'goto': goto,
    'uri': uri,
    'cover': cover,
    'duration': duration,
    'pubdate': pubdate,
    'desc': desc,
    'rcmdReason': rcmdReason,
    'isFollowed': isFollowed,
    'param': param,
    'pgcBadge': pgcBadge,
    'ownerMid': owner.mid,
    'ownerName': owner.name,
    'view': stat.view,
    'like': stat.like,
    'danmu': stat.danmu,
    'talkBack': talkBack,
    'cardType': cardType,
    'threePoint': threePoint?.toCacheJson(),
  };
}

class RcmdStat extends BaseStat {
  RcmdStat.fromJson(Map<String, dynamic> json) {
    view = NumUtils.parseNum(json["cover_left_text_1"] ?? '');
    danmu = NumUtils.parseNum(json["cover_left_text_2"] ?? '');
  }
}

class RcmdOwner extends BaseOwner {
  RcmdOwner.fromJson(Map<String, dynamic> json, String? goto) {
    name = goto == 'av'
        ? (json['args']?['up_name'] ?? '')
        : (json['desc_button']?['text'] ?? '');
    mid = json['args']?['up_id'] ?? 0;
  }
}

class ThreePoint {
  List<Reason>? dislikeReasons;
  List<Reason>? feedbacks;
  // int? watchLater;

  ThreePoint.fromJson(List json) {
    for (final elem in json) {
      switch (elem['type']) {
        // case 'watch_later':
        //   watchLater = 1;
        //   break;
        case 'feedback':
          feedbacks = (elem['reasons'] as List?)
              ?.map((i) => Reason.fromJson(i))
              .toList();
          break;
        case 'dislike':
          dislikeReasons = (elem['reasons'] as List?)
              ?.map((i) => Reason.fromJson(i))
              .toList();
          break;
      }
    }
  }

  ThreePoint.fromCacheJson(Map<String, dynamic> json) {
    dislikeReasons = _reasonsOf(json['dislike']);
    feedbacks = _reasonsOf(json['feedback']);
  }

  Map<String, dynamic> toCacheJson() => {
    'dislike': dislikeReasons?.map((r) => r.toCacheJson()).toList(),
    'feedback': feedbacks?.map((r) => r.toCacheJson()).toList(),
  };

  static List<Reason>? _reasonsOf(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final reason in raw)
        if (reason is Map) Reason.fromCacheJson(reason.cast<String, dynamic>()),
    ];
  }
}

class Reason {
  int? id;
  String? name;
  String? toast;

  Reason.fromJson(Map<String, dynamic> json) {
    id = json['id'];
    name = json['name'];
    toast = json['toast'];
  }

  Reason.fromCacheJson(Map<String, dynamic> json) {
    id = safeToInt(json['id']);
    name = json['name'] as String?;
    toast = json['toast'] as String?;
  }

  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'name': name,
    'toast': toast,
  };
}
