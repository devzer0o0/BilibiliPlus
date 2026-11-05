import 'package:flutter/foundation.dart';

/// What one layer of the AV1 path answered.
///
/// Three states, not two. "Nobody asked" and "this device cannot" are different
/// facts, and collapsing them is how a probe that has not run yet becomes a
/// permanent "AV1 unsupported": the first version of this branch had a single
/// `av1HardwareAvailable` bool that defaulted to true and could only be flipped
/// by a platform channel that fails silently, so the answer was a guess in both
/// directions.
enum CapabilityState {
  /// Not established. Treated as "keep AV1 in the order": demoting on a missing
  /// answer loses a capability that is present, and the session's own evidence
  /// arrives by the first frame anyway.
  unknown,

  /// Established as available.
  supported,

  /// Established as unavailable. Only this state may demote AV1.
  unsupported,
}

/// What the running playback session has demonstrated so far.
///
/// A request (`hwdec=videotoolbox`) is not a result. This is the result, and it
/// only moves forward from [starting] on evidence.
enum SessionDecodeState {
  /// No source is open, or nothing has been observed yet.
  idle,

  /// A source is open and the decoder has not reported yet. Must not be read as
  /// a failure: on the first frames mpv has no `hwdec-current` value at all.
  starting,

  /// Frames are arriving from a hardware decoder.
  hardware,

  /// Frames are arriving from a software decoder.
  software,

  /// The decoder reported a failure for this session.
  failed,
}

/// What is known about AV1 hardware decoding, layer by layer.
///
/// The layers are separate on purpose. "The chip can decode AV1" and "this build
/// can decode AV1" and "this backend can present it" fail independently, and a
/// single bool cannot say which one went wrong - which is exactly the question
/// the device evidence had to answer by hand.
@immutable
class Av1Capability {
  const Av1Capability({
    this.system = CapabilityState.unknown,
    this.mediaLibrary = CapabilityState.unknown,
    this.backend = CapabilityState.unknown,
    this.session = SessionDecodeState.idle,
    this.mediaLibraryVersion,
    this.identity,
  });

  /// VideoToolbox on this device: `VTIsHardwareDecodeSupported`.
  ///
  /// Says nothing about this app. A build without an AV1-capable Avcodec runs on
  /// a phone that answers `true` here and still decodes on the CPU.
  final CapabilityState system;

  /// The Avcodec actually loaded by this process: does it register a
  /// VideoToolbox hwaccel for the AV1 decoder.
  ///
  /// Read from the loaded binary, not from a build flag, so an app that shipped
  /// without the AV1 framework answers [CapabilityState.unsupported] instead of
  /// claiming a capability it does not have.
  final CapabilityState mediaLibrary;

  /// Whether the active backend can carry AV1 to the screen at all.
  final CapabilityState backend;

  /// What this playback session has shown so far.
  final SessionDecodeState session;

  /// Version string of the loaded Avcodec, for the record.
  final String? mediaLibraryVersion;

  /// Cache key the answer belongs to: OS build, app build, library version.
  final String? identity;

  bool get canSelectAv1 => mediaLibrary != CapabilityState.unsupported;

  /// AV1 is being decoded on the CPU right now.
  bool get runningSoftware => session == SessionDecodeState.software;

  Av1Capability copyWith({
    CapabilityState? system,
    CapabilityState? mediaLibrary,
    CapabilityState? backend,
    SessionDecodeState? session,
    String? mediaLibraryVersion,
    String? identity,
  }) =>
      Av1Capability(
        system: system ?? this.system,
        mediaLibrary: mediaLibrary ?? this.mediaLibrary,
        backend: backend ?? this.backend,
        session: session ?? this.session,
        mediaLibraryVersion: mediaLibraryVersion ?? this.mediaLibraryVersion,
        identity: identity ?? this.identity,
      );

  /// One line for the diagnostics file. Never invents an answer: a layer that
  /// has not reported shows as `unknown`.
  @override
  String toString() =>
      'Av1Capability(system=${system.name} library=${mediaLibrary.name} '
      'backend=${backend.name} session=${session.name} '
      'lib=${mediaLibraryVersion ?? '-'} id=${identity ?? '-'})';
}
