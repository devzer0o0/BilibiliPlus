import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel;

import 'package:PiliPlus/plugin/pl_player/models/av1_capability.dart';
import 'package:PiliPlus/plugin/pl_player/utils/playback_diagnostics.dart';

/// Asks the platform which of the AV1 layers are available, and remembers the
/// answer only for as long as it is still about the same thing.
///
/// The answer is stored with an identity string (OS build plus the version of
/// the loaded Avcodec). A different identity starts from [CapabilityState.unknown]
/// rather than inheriting the previous answer, because that is the shape of the
/// bug this replaces: a cached "unsupported" surviving an app upgrade that added
/// the decoder, or a cached "supported" surviving a downgrade that removed it.
abstract final class Av1CapabilityProbe {
  static const MethodChannel _channel = MethodChannel(
    'pilipilus/hdr_video/control',
  );

  static Av1Capability _capability = const Av1Capability();

  /// Bumped every time a fresh answer is adopted, so a session that started
  /// under an older answer can notice.
  static int _generation = 0;

  static Av1Capability get capability => _capability;

  static int get generation => _generation;

  /// Asks the platform, and adopts the answer when it is about this build.
  ///
  /// A failure leaves every layer [CapabilityState.unknown] and records why. It
  /// must not become "unsupported": a channel that is not ready yet is not a
  /// statement about the decoder, and treating it as one demotes AV1 on a device
  /// that can decode it.
  static Future<Av1Capability> refresh({bool force = false}) async {
    try {
      final raw = await _channel.invokeMethod<Map>('av1DecoderProbe');
      final libraryVersion = raw?['libraryVersion'] as String?;
      final identity = _identity(libraryVersion);
      if (!force && _capability.identity == identity) {
        return _capability;
      }
      final probeAvailable = raw?['available'] == true;
      final hasAv1VideoToolbox = raw?['av1VideoToolbox'] == true;
      // Built from the current record, not from scratch: replacing the whole
      // object dropped the system layer that had already answered, so the log
      // read `system=unknown` next to a recorded `VTIsHardwareDecodeSupported=true`.
      final decoded = _capability.copyWith(
        mediaLibrary: probeAvailable
            ? (hasAv1VideoToolbox
                  ? CapabilityState.supported
                  : CapabilityState.unsupported)
            : CapabilityState.unknown,
        mediaLibraryVersion: libraryVersion,
        identity: identity,
      );
      _adopt(decoded);
      PlaybackDiagnostics.record(
        'av1-probe',
        'available=$probeAvailable av1VT=$hasAv1VideoToolbox '
            'lib=${libraryVersion ?? "?"} reason=${raw?['reason'] ?? "-"} '
            'hwConfigs=${raw?['hwConfigs'] ?? "-"}',
      );
      return _capability;
    } catch (err) {
      PlaybackDiagnostics.record('av1-probe', 'failed: $err');
      return _capability;
    }
  }

  /// Records what VideoToolbox answered about the chip itself.
  ///
  /// Kept apart from [mediaLibrary] on purpose: this is the layer that stays
  /// true across a broken build, and reading it as "AV1 works" is exactly the
  /// inference that hid the missing framework.
  static void observeSystem(bool supported) {
    _adopt(
      _capability.copyWith(
        system: supported ? CapabilityState.supported : CapabilityState.unsupported,
      ),
    );
    PlaybackDiagnostics.record(
      'av1-system',
      'VTIsHardwareDecodeSupported(av1)=$supported',
    );
  }

  /// Records what the backend in use can carry.
  static void observeBackend(CapabilityState state) {
    if (_capability.backend == state) return;
    _adopt(_capability.copyWith(backend: state));
  }

  /// Records what this playback session has demonstrated.
  ///
  /// Session state never feeds back into the cached library/backend answer: a
  /// single stream that falls back to software says something about that stream,
  /// not about the decoder, and writing it into the capability would disable AV1
  /// for every later video.
  static void observeSession(SessionDecodeState state) {
    if (_capability.session == state) return;
    _capability = _capability.copyWith(session: state);
  }

  /// Forgets everything, for a new app build or an explicit re-probe.
  static void invalidate() {
    _capability = const Av1Capability();
    _generation++;
  }

  static void _adopt(Av1Capability next) {
    _capability = next;
    _generation++;
  }

  /// OS build plus library version: the two things that decide this answer.
  static String _identity(String? libraryVersion) =>
      '${Platform.operatingSystem}:${Platform.operatingSystemVersion}:'
      '${libraryVersion ?? "unknown"}';
}
