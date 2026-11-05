// ignore_for_file: constant_identifier_names

enum VideoDecodeFormatType {
  // Dolby Vision has two sample-entry four-character codes and both are
  // served: `dvh1` (the common one) and `dvhe`. Listing only the first meant
  // `dvhe.08.10` matched no format at all, and fromString threw.
  DVH1(['dvh1', 'dvhe']),
  AV1(['av01']),
  HEVC(['hev1', 'hvc1']),
  AVC(['avc1']),
  ;

  /// What the settings UI shows. `DVH1` is the four-character code, not a
  /// name anyone recognises, so the Dolby entries say what they are.
  String get description => switch (this) {
    DVH1 => '杜比视界 (DV)',
    AV1 => 'AV1',
    HEVC => 'H.265 / HEVC',
    AVC => 'H.264 / AVC',
  };
  final List<String> codes;

  const VideoDecodeFormatType(this.codes);

  /// Resolves a codec string to the format that describes it.
  ///
  /// Falls back to [AVC] instead of throwing: `firstWhere` without a default
  /// raises "No element", and this runs while opening a video and while
  /// building the quality list. A sample entry nobody has taught it about yet
  /// (a new codec, a vendor string) must degrade to the generic path rather
  /// than take the screen down.
  static VideoDecodeFormatType fromString(String val) =>
      values.firstWhere(
        (i) => i.codes.any(val.startsWith),
        orElse: () => AVC,
      );
}
