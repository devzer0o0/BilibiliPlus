import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// MainLayout pins the bottom navigation to the screen edge and the bar
/// widgets apply their own SafeArea. The bar is therefore wrapped in a
/// MediaQuery that removes BOTH vertical insets; removing only the top one
/// left the 34 pt home-indicator inset applied twice on iPhone Air, drawing
/// an empty strip below the labels.
void main() {
  const homeIndicatorInset = 34.0;
  const topInset = 47.0;

  Widget probe({required bool removeBottom}) {
    return MediaQuery(
      data: const MediaQueryData(
        size: Size(420, 912),
        padding: EdgeInsets.only(top: topInset, bottom: homeIndicatorInset),
        viewPadding: EdgeInsets.only(
          top: topInset,
          bottom: homeIndicatorInset,
        ),
      ),
      child: Builder(
        builder: (outer) => MediaQuery.removePadding(
          context: outer,
          removeTop: true,
          removeBottom: removeBottom,
          child: Builder(
            builder: (inner) {
              final mq = MediaQuery.of(inner);
              return Directionality(
                textDirection: TextDirection.ltr,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    key: const Key('probe'),
                    width: 1,
                    height: 1 + mq.padding.bottom,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  testWidgets('removing the bottom inset zeroes the bar padding', (
    tester,
  ) async {
    await tester.pumpWidget(probe(removeBottom: true));
    final size = tester.getSize(find.byKey(const Key('probe')));
    expect(size.height, 1);
  });

  testWidgets('leaving the bottom inset keeps the 34 pt strip', (tester) async {
    await tester.pumpWidget(probe(removeBottom: false));
    final size = tester.getSize(find.byKey(const Key('probe')));
    expect(size.height, 1 + homeIndicatorInset);
  });
}