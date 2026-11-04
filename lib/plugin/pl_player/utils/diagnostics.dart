/// Test-only switches, compiled out of a release build.
///
/// A runtime `--dart-define` is also a compile-time constant in Flutter, so
/// these become literal `false` branches and the tree shaker removes them.
/// Nothing here may be reachable in a shipping build: the release constraint
/// check greps the binary for these markers.
abstract final class Diagnostics {
  /// Enables the decoder probe and the measurement surfaces.
  ///
  ///   flutter build ios --profile --dart-define=PILIPLUS_DIAGNOSTICS=true
  static const bool enabled = bool.fromEnvironment('PILIPLUS_DIAGNOSTICS');

  /// Sampling interval for decoder counters. Long enough not to perturb the
  /// thing being measured: a 250 ms poll of six properties costs frames.
  static const Duration sampleInterval = Duration(seconds: 2);
}
