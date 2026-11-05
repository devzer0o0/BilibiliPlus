import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// The home feed used to sit on its skeleton forever when the recommend
/// endpoint failed: the fetch returned an error, the page had no cards to keep,
/// and that combination never replaced the Loading state. There was no message
/// and no retry - the screen simply never filled.
///
/// Both ways a fetch can go wrong have to end in a state the user can act on:
/// a returned Error, and an exception thrown out of the fetch.

class _FakeListController extends CommonListController<List<int>, int> {
  _FakeListController({
    required this.outcome,
    this.keepCardsOnError = false,
  });

  /// 'error' -> returns Error, 'throw' -> throws, 'ok' -> returns one item.
  final String outcome;

  /// Mirrors RcmdController.handleError: only keep the screen when there is
  /// something on it worth keeping.
  final bool keepCardsOnError;

  @override
  Future<LoadingState<List<int>>> customGetData() async {
    switch (outcome) {
      case 'throw':
        throw StateError('connection reset');
      case 'ok':
        return const Success([1]);
      default:
        return Error('server said no');
    }
  }

  @override
  bool handleError(String? errMsg) {
    if (!keepCardsOnError) return false;
    if (loadingState.value case Success(:final response)) {
      return response != null && response.isNotEmpty;
    }
    return false;
  }

  @override
  List<int>? getDataList(List<int> response) => response;
}

void main() {
  test('a thrown fetch ends in Error instead of staying on the skeleton', () async {
    final controller = _FakeListController(outcome: 'throw');
    expect(controller.loadingState.value, isA<Loading>());

    await controller.queryData();

    expect(controller.loadingState.value, isA<Error>());
    expect(controller.isLoading, isFalse);
  });

  test('an Error with no cards left to keep still reaches the Error state',
      () async {
    final controller = _FakeListController(
      outcome: 'error',
      keepCardsOnError: true,
    );

    await controller.queryData();

    expect(controller.loadingState.value, isA<Error>());
  });

  test('an Error keeps the cards already on screen', () async {
    final controller = _FakeListController(
      outcome: 'ok',
      keepCardsOnError: true,
    );
    await controller.queryData();
    expect(controller.loadingState.value, isA<Success>());

    final failed = _FakeListController(
      outcome: 'error',
      keepCardsOnError: true,
    );
    failed.loadingState.value = const Success([7, 8]);
    await failed.queryData();

    final state = failed.loadingState.value;
    expect(state, isA<Success>());
    expect((state as Success).response, [7, 8]);
  });
}
