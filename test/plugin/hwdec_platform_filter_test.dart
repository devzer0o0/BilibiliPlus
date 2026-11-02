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
}