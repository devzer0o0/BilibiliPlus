import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models/model_video.dart';
import 'package:PiliPlus/utils/parse_int.dart';

abstract class BaseRcmdVideoItemModel extends BaseVideoItemModel {
  String? goto;
  String? uri;
  String? rcmdReason;

  // app推荐专属
  int? param;
  String? pgcBadge;

  /// The display fields a card needs, in a flat map the home feed cache can
  /// persist. Kept here next to [BaseVideoItemModel] so a new field added to
  /// the base model is visible to whoever extends this contract.
  Map<String, dynamic> toCacheJson();
}

class RcmdVideoItemModel extends BaseRcmdVideoItemModel {
  RcmdVideoItemModel.fromJson(Map<String, dynamic> json) {
    aid = json["id"];
    bvid = json["bvid"];
    cid = json["cid"];
    goto = json["goto"];
    uri = json["uri"];
    cover = json["pic"];
    title = json["title"];
    duration = json["duration"];
    pubdate = json["pubdate"];
    owner = Owner.fromJson(json["owner"]);
    stat = Stat.fromJson(json["stat"]);
    isFollowed = json["is_followed"] == 1;
    // rcmdReason = json["rcmd_reason"] != null
    //     ? RcmdReason.fromJson(json["rcmd_reason"])
    //     : RcmdReason(content: '');
    rcmdReason = json["rcmd_reason"]?['content'];
  }

  /// Rebuilds a card from the home feed cache. The cache is display-only, so
  /// fields the feed did not carry stay null instead of being guessed.
  RcmdVideoItemModel.fromCacheJson(Map<String, dynamic> json) {
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
  }

  @override
  Map<String, dynamic> toCacheJson() => {
    'kind': 'web',
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
  };

  // @override
  // String? get desc => null;
}

// @HiveType(typeId: 2)
// class RcmdReason {
//   RcmdReason({
//     this.reasonType,
//     this.content,
//   });
// //   int? reasonType;
// //   String? content;
//
//   RcmdReason.fromJson(Map<String, dynamic> json) {
//     reasonType = json["reason_type"];
//     content = json["content"] ?? '';
//   }
// }
