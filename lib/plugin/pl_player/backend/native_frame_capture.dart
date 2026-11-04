import 'package:flutter/services.dart';

/// One frame taken from the native player.
///
/// Carries what was actually captured, because a screenshot is evidence only if
/// its size, colour space and whether HDR was mapped down are recorded with it.
class CapturedFrame {
  const CapturedFrame({
    required this.png,
    required this.width,
    required this.height,
    required this.frameMs,
    required this.colorSpace,
    required this.toneMapped,
  });

  final Uint8List png;
  final int width;
  final int height;

  /// The media time of the captured frame, not the wall clock at the click.
  final int frameMs;

  /// e.g. `sRGB`.
  final String colorSpace;

  /// True when an HDR source had to be mapped to SDR for this PNG.
  final bool toneMapped;

  static CapturedFrame? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final bytes = map['png'];
    if (bytes is! Uint8List) return null;
    return CapturedFrame(
      png: bytes,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      frameMs: (map['frameMs'] as num?)?.toInt() ?? 0,
      colorSpace: map['colorSpace'] as String? ?? 'unknown',
      toneMapped: map['toneMapped'] == true,
    );
  }
}

/// Frame extraction for the AVPlayerLayer backend.
///
/// Routed through the same control channel as playback so it stays keyed by the
/// session: a capture that arrives after a source switch is refused instead of
/// returning a frame from the previous video.
abstract final class NativeFrameCapture {
  static const _channel = MethodChannel('pilipilus/hdr_video/control');

  static Future<CapturedFrame?> capture(String sessionId) async {
    try {
      final result = await _channel.invokeMethod<Map>('captureFrame', {
        'sessionId': sessionId,
      });
      return CapturedFrame.fromMap(result);
    } catch (_) {
      return null;
    }
  }
}
