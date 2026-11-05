// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';

import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:flutter/foundation.dart';

/// The fields the AI feature is allowed to see about one candidate.
///
/// Built from what the feed already returned. No detail request, no subtitle,
/// no comment text and no account identifier is fetched or attached.
@immutable
class VideoFeatures {
  const VideoFeatures({
    required this.bvid,
    required this.title,
    this.description,
    this.category,
    this.durationSeconds = 0,
    this.ownerMid,
    this.ownerName,
    this.pubdate,
    this.viewCount,
    this.likeCount,
    this.isFollowed = false,
    this.upstreamIndex = 0,
    this.source = 'unknown',
  });

  final String bvid;
  final String title;
  final String? description;
  final String? category;
  final int durationSeconds;
  final int? ownerMid;
  final String? ownerName;
  final int? pubdate;
  final int? viewCount;
  final int? likeCount;
  final bool isFollowed;
  final int upstreamIndex;
  final String source;

  /// Text used by local keyword/topic matching only.
  String get matchText =>
      title.toLowerCase() + '\n' + (description ?? '').toLowerCase();

  factory VideoFeatures.fromRecommendation(
    BaseRcmdVideoItemModel item, {
    required int index,
    required String source,
  }) {
    final title = _clean(item.title, 200);
    final desc = _clean(item.desc, 300);
    return VideoFeatures(
      bvid: item.bvid ?? '',
      title: title,
      description: desc.isEmpty ? null : desc,
      category: switch (item.goto) {
        'av' => '视频',
        'bangumi' => '番剧',
        'picture' => '动态',
        _ => null,
      },
      durationSeconds: item.duration > 0 ? item.duration : 0,
      ownerMid: item.owner.mid,
      ownerName: _clean(item.owner.name, 60),
      pubdate: item.pubdate,
      viewCount: item.stat.view,
      likeCount: item.stat.like,
      isFollowed: item.isFollowed,
      upstreamIndex: index,
      source: source,
    );
  }

  /// A small, explicit payload for one model request. Stable request-local IDs
  /// are added by the request builder, never persisted.
  Map<String, dynamic> toJson() => {
    'title': _clean(title, 200),
    if (description != null) 'description': _clean(description!, 300),
    if (category != null) 'category': category,
    'durationSeconds': durationSeconds.clamp(0, 24 * 3600),
  };

  static String _clean(String? value, int max) {
    if (value == null) return '';
    final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > max ? flat.substring(0, max) : flat;
  }

  @override
  String toString() => 'VideoFeatures(' + bvid + ', ' + title + ')';
}

/// A compact, versioned view of one candidate used by the provider prompt and
/// the cache key. Keeping this separate from the Hive model means the request
/// body cannot grow by accident when a feed adds a field.
@immutable
class AiCandidateEnvelope {
  const AiCandidateEnvelope({
    required this.requestId,
    required this.features,
  });

  final String requestId;
  final VideoFeatures features;

  Map<String, dynamic> toJson() => {
    'candidateId': requestId,
    ...features.toJson(),
  };
}

/// Deterministic, non-cryptographic request id. c1..cN is enough: ids must be
/// unique within one request and must not encode the bvid.
String requestIdForIndex(int index) => 'c' + (index + 1).toString();

/// Builds the exact user message payload. Pure so tests can assert what is and
/// is not sent.
String buildCandidatePayloadJson(List<AiCandidateEnvelope> candidates) =>
    jsonEncode(candidates.map((c) => c.toJson()).toList());
