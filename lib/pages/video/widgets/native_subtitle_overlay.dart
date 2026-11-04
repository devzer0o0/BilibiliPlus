import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/subtitle_cue.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

export 'package:PiliPlus/plugin/pl_player/models/subtitle_cue.dart'
    show SubtitleCue, parseSubtitleCues, subtitleTextAt;

/// Draws a subtitle cue in Flutter.
///
/// The normal path hands the track to mpv and lets `SubtitleView` render what
/// mpv decoded. That cannot work on the native HDR path, where mpv is not the
/// player, so the cue is looked up here instead - from the same [SubtitleCue]
/// list mpv's VTT is generated from.
class NativeSubtitleOverlay extends StatefulWidget {
  const NativeSubtitleOverlay({
    super.key,
    required this.controller,
    required this.cues,
  });

  final PlPlayerController controller;

  /// Cues in seconds, sorted by start.
  final List<SubtitleCue> cues;

  @override
  State<NativeSubtitleOverlay> createState() => _NativeSubtitleOverlayState();
}

class _NativeSubtitleOverlayState extends State<NativeSubtitleOverlay> {
  String _text = '';

  /// Resolves the subscription. `ever` registers on the controller, which
  /// outlives this widget, so dropping the handle would leave a callback firing
  /// setState on a disposed State after every rebuild.
  late final Worker _worker;

  @override
  void initState() {
    super.initState();
    _worker = ever(widget.controller.position, _update);
    _update(widget.controller.position.value);
  }

  @override
  void didUpdateWidget(covariant NativeSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new track or a new video must be re-evaluated immediately instead of
    // waiting for the next position tick.
    if (!identical(oldWidget.cues, widget.cues) ||
        !identical(oldWidget.controller, widget.controller)) {
      _update(widget.controller.position.value);
    }
  }

  @override
  void dispose() {
    _worker.dispose();
    super.dispose();
  }

  /// [PlPlayerController.position] counts whole seconds, so the cue lookup
  /// takes it as-is.
  ///
  /// Dividing it by 1000 again made every cue unreachable after the first
  /// second: the overlay asked for 0.002s when playback was at 2s.
  void _update(int seconds) {
    final found = subtitleTextAt(widget.cues, seconds.toDouble());
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

/// Kept as the name the page and its tests already use.
List<SubtitleCue> parseNativeSubtitle(String jsonBody) =>
    parseSubtitleCues(jsonBody);
