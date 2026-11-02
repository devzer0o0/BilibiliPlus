import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:flutter_test/flutter_test.dart';

/// The path a playurl failure actually takes to the screen:
///
///   parseVideoErr -> Error(errMsg) -> LoadingState.toast() -> toString()
///
/// The last step returns errMsg verbatim, so whatever parseVideoErr produces
/// is exactly what the toast shows. Asserting the two ends together catches a
/// break anywhere along the chain, which asserting parseVideoErr alone does not.
void main() {
  String shownFor(int? code, String? msg) =>
      Error(VideoHttp.parseVideoErr(code, msg)).toString();

  test('a paywalled video shows a clean sentence', () {
    final shown = shownFor(87008, '充电专属');
    expect(shown, contains('专属视频'));
    expect(shown, isNot(contains('})')));
    expect(shown, isNot(contains('null')));
  });

  test('a deleted video shows the deletion text, not the raw code', () {
    final shown = shownFor(-404, '啥都木有');
    expect(shown, '视频不存在或已被删除');
    expect(shown, isNot(contains('-404')));
  });

  test('DRM content explains itself instead of showing a bare code', () {
    final shown = shownFor(-10403, 'copyright');
    expect(shown, contains('版权保护'));
    expect(shown, isNot(contains('copyright')));
  });

  test('an unknown code still names both the code and the message', () {
    final shown = shownFor(-999, 'boom');
    expect(shown, contains('-999'));
    expect(shown, contains('boom'));
  });

  test('no case produces an empty toast', () {
    const codes = <int?>[-404, 87008, -10403, -999, null];
    for (final code in codes) {
      expect(shownFor(code, 'msg'), isNotEmpty, reason: 'code $code');
    }
  });
}