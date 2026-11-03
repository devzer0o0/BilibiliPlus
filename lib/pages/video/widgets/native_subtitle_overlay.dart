import 'dart:convert';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Draws a subtitle cue in Flutter.
///
/// The normal path hands the track to mpv and lets `SubtitleView` render what
/// mpv decoded. That cannot work on the native HDR path, where mpv is not the
/// player, so the cue is looked up here instead - the account already ships the
/// subtitle as JSON, so nothing has to be fetched twice.
class NativeSubtitleOverlay extends StatefulWidget {
  const NativeSubtitleOverlay({
    super.key,
    required this.controller,
    required this.cues,
  });

  final PlPlayerController controller;

  /// Cues in seconds, sorted by start.
  final List<({double from, double to, String text})> cues;

  @override
  State<NativeSubtitleOverlay> createState() => _NativeSubtitleOverlayState();
}

class _NativeSubtitleOverlayState extends State<NativeSubtitleOverlay> {
  String _text = '';

  @override
  void initState() {
    super.initState();
    ever(widget.controller.position, _update);
  }

  void _update(int ms) {
    final found = subtitleTextAt(widget.cues, ms / 1000);
    if (found != _text && mounted) {
      setState(() => _text = found);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_text.isEmpty) return const SizedBox.shrink();
    final config = widget.controller.subtitleConfig.value;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: widget.controller.subtitlePaddingB.toDouble() + 24,
          left: 16,
          right: 16,
        ),
        child: Text(
          _text,
          textAlign: TextAlign.center,
          style: config.style.copyWith(
            shadows: const [
              Shadow(blurRadius: 4, color: Colors.black87, offset: Offset(0, 1)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The cue covering [seconds], or empty when none does.
///
/// Extracted so the visibility rule can be asserted without building a player:
/// the widget only repaints what this decides.
String subtitleTextAt(
  List<({double from, double to, String text})> cues,
  double seconds,
) {
  for (final c in cues) {
    if (seconds >= c.from && seconds <= c.to) return c.text;
  }
  return '';
}

/// Parses the `{"from", "to", "content"}` list bilibili returns for a subtitle.
List<({double from, double to, String text})> parseNativeSubtitle(
  String jsonBody,
) {
  final list = jsonDecode(jsonBody);
  if (list is! List) return const [];
  final out = <({double from, double to, String text})>[];
  for (final e in list) {
    if (e is! Map) continue;
    final from = (e['from'] as num?)?.toDouble();
    final to = (e['to'] as num?)?.toDouble();
    final text = e['content'] as String?;
    if (from == null || to == null || text == null || text.isEmpty) continue;
    out.add((from: from, to: to, text: text));
  }
  out.sort((a, b) => a.from.compareTo(b.from));
  return out;
}
