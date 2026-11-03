import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// The hwdec dialog lists every mpv backend by default, so an iPhone user had
/// to scroll past DirectX/VAAPI/CUDA to reach videotoolbox. valuesForPlatform
/// keeps only the generic entries plus the backends this OS actually has.
void main() {
  test('generic decode modes are always offered', () {
    final values = HwDecType.valuesForPlatform;
    for (final e in [
      HwDecType.no,
      HwDecType.auto,
      HwDecType.autoSafe,
      HwDecType.autoCopy,
    ]) {
      expect(values, contains(e));
    }
  });

  test('the list is filtered to the running platform', () {
    final values = HwDecType.valuesForPlatform.toSet();
    if (Platform.isIOS || Platform.isMacOS) {
      expect(values, contains(HwDecType.videotoolbox));
      expect(values, isNot(contains(HwDecType.d3d11va)));
      expect(values, isNot(contains(HwDecType.vaapi)));
      expect(values, isNot(contains(HwDecType.mediacodec)));
      expect(values, isNot(contains(HwDecType.nvdec)));
    }
    if (Platform.isAndroid) {
      expect(values, contains(HwDecType.mediacodec));
      expect(values, isNot(contains(HwDecType.videotoolbox)));
    }
  });

  test('the filtered list is shorter than the enum', () {
    expect(
      HwDecType.valuesForPlatform.length,
      lessThan(HwDecType.values.length),
    );
  });

  test('no duplicates leak through the filter', () {
    final list = HwDecType.valuesForPlatform;
    expect(list.toSet().length, list.length);
  });

  test('iOS does not offer the copy-back VideoToolbox variant', () {
    // iPhone Air never uses it: VideoToolbox hands frames over directly, so
    // device logs always show hwdec=videotoolbox. The transcoder appends its
    // own ",auto-copy", so nothing depends on the entry being listed.
    if (!Platform.isIOS) return;
    final values = HwDecType.valuesForPlatform;
    expect(values, contains(HwDecType.videotoolbox));
    expect(values, isNot(contains(HwDecType.videotoolboxCopy)));
  });

  test('iOS keeps the decode modes it still needs', () {
    if (!Platform.isIOS) return;
    final values = HwDecType.valuesForPlatform.toSet();
    // auto is the shipped default, auto-safe is the fallback if VideoToolbox
    // cannot handle a codec, and no turns hardware decoding off entirely.
    expect(values, contains(HwDecType.auto));
    expect(values, contains(HwDecType.autoSafe));
    expect(values, contains(HwDecType.no));
  });

  test('macOS keeps both VideoToolbox variants', () {
    // Only iOS dropped the copy variant; macOS is a different machine and was
    // not part of this change.
    if (!Platform.isMacOS) return;
    final values = HwDecType.valuesForPlatform.toSet();
    expect(values, contains(HwDecType.videotoolbox));
    expect(values, contains(HwDecType.videotoolboxCopy));
  });

  group('valuesFor(platform)', () {
    test('ios drops the copy-back VideoToolbox variant', () {
      final ios = HwDecType.valuesFor('ios').toSet();
      expect(ios, contains(HwDecType.videotoolbox));
      expect(ios, isNot(contains(HwDecType.videotoolboxCopy)));
    });

    test('ios keeps every decode mode it still needs', () {
      final ios = HwDecType.valuesFor('ios').toSet();
      // auto is the shipped default on iOS, auto-safe is the fallback when
      // VideoToolbox cannot take a codec, and no disables hardware decoding.
      expect(ios, contains(HwDecType.auto));
      expect(ios, contains(HwDecType.autoSafe));
      expect(ios, contains(HwDecType.no));
    });

    test('ios offers nothing from another platform', () {
      final ios = HwDecType.valuesFor('ios').toSet();
      for (final e in [
        HwDecType.mediacodec,
        HwDecType.d3d11va,
        HwDecType.vaapi,
        HwDecType.nvdec,
      ]) {
        expect(ios, isNot(contains(e)));
      }
    });

    test('macos and android are untouched', () {
      expect(
        HwDecType.valuesFor('macos'),
        contains(HwDecType.videotoolboxCopy),
      );
      expect(HwDecType.valuesFor('android'), contains(HwDecType.mediacodec));
      expect(HwDecType.valuesFor('windows'), contains(HwDecType.d3d11va));
      expect(HwDecType.valuesFor('linux'), contains(HwDecType.vaapi));
    });

    test('the transcoder can still ask for auto-copy', () {
      // mpv_convert_webp.dart appends ",auto-copy" itself, so removing the
      // list entry must not break animated screenshots.
      expect(HwDecType.autoCopy.hwdec, 'auto-copy');
      expect(HwDecType.autoSafe.hwdec, 'auto-safe');
    });
  });
}
