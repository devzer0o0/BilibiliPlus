import 'dart:convert';

/// One subtitle line, in seconds.
///
/// The single subtitle contract: the HTTP layer produces cues, mpv gets a VTT
/// generated from them, and the native overlay draws them. Callers never have
/// to know which text format a given code path expects.
typedef SubtitleCue = ({double from, double to, String text});

/// Parses the subtitle payload bilibili returns.
///
/// Two shapes reach this function and both are accepted: the endpoint's
/// envelope `{"body":[...]}` and the bare `[{"from","to","content"}]`
/// list. Anything else - malformed JSON, an error object, a VTT string - yields
/// no cues instead of throwing, so a broken track cannot break playback.
List<SubtitleCue> parseSubtitleCues(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  if (decoded is Map && decoded['body'] is List) {
    decoded = decoded['body'];
  }
  if (decoded is! List) return const [];
  final out = <SubtitleCue>[];
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final from = (entry['from'] as num?)?.toDouble();
    final to = (entry['to'] as num?)?.toDouble();
    final text = entry['content'] as String?;
    if (from == null || to == null || text == null || text.isEmpty) continue;
    if (!from.isFinite || !to.isFinite || to < from) continue;
    out.add((from: from, to: to, text: text));
  }
  out.sort((a, b) => a.from.compareTo(b.from));
  return out;
}

/// The cue covering [seconds], or empty when none does.
String subtitleTextAt(List<SubtitleCue> cues, double seconds) {
  for (final c in cues) {
    if (seconds >= c.from && seconds <= c.to) return c.text;
  }
  return '';
}
