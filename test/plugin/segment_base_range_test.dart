import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// The playurl response already contains the initialization and index ranges.
/// They are passed through unchanged; guessing them again on the client is how
/// every fragment after the first ends up at the wrong offset.
void main() {
  test('parses the shape the service sends', () {
    final range = SegmentBaseRange.fromJson({
      'Initialization': '0-999',
      'indexRange': '1000-1259',
    });
    expect(range, isNotNull);
    expect(range!.initialization, '0-999');
    expect(range.index, '1000-1259');
    expect(range.toMap(), {'init': '0-999', 'index': '1000-1259'});
  });

  test('accepts snake_case as well as the camel form', () {
    final range = SegmentBaseRange.fromJson({
      'initialization': '0-933',
      'index_range': '934-1205',
    });
    expect(range?.index, '934-1205');
  });

  test('a missing or half-declared base is null, not an empty range', () {
    expect(SegmentBaseRange.fromJson(null), isNull);
    expect(SegmentBaseRange.fromJson({'Initialization': '0-999'}), isNull);
    expect(
      SegmentBaseRange.fromJson({'Initialization': '', 'indexRange': '1-2'}),
      isNull,
    );
  });

  test('the request carries both ranges to the backend', () {
    const request = PlaybackRequest(
      sourceKey: 'BV1:100:125:hev1',
      videoUrl: 'https://cdn.example/v.m4s',
      audioUrl: 'https://cdn.example/a.m4s',
      videoSegmentBase: SegmentBaseRange(
        initialization: '0-999',
        index: '1000-1259',
      ),
      audioSegmentBase: SegmentBaseRange(
        initialization: '0-933',
        index: '934-1205',
      ),
    );
    expect(request.videoSegmentBase?.index, '1000-1259');
    expect(request.audioSegmentBase?.initialization, '0-933');
  });
}
