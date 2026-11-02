import 'package:PiliPlus/plugin/pl_player/widgets/play_error_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The panel replaces the player when playurl fails. Its layout used to be an
/// unbounded column, so a long message in a short player area overflowed.
void main() {
  Widget host(Widget child, {Size size = const Size(420, 236)}) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: child,
            ),
          ),
        ),
      );

  testWidgets('shows the message and a retry button', (tester) async {
    await tester.pumpWidget(
      host(
        PlayErrorPanel(
          message: '视频不存在或已被删除',
          onRetry: () {},
        ),
      ),
    );
    expect(find.text('视频不存在或已被删除'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('tapping retry invokes the callback once', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(PlayErrorPanel(message: '加载失败', onRetry: () => taps++)),
    );
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('a long message does not overflow a short player area',
      (tester) async {
    // The paywall message is the longest parseVideoErr can produce.
    const long = '当前视频可能是专属视频，可能需包月充电观看(充电专属内容需要付费)';
    await tester.pumpWidget(
      host(
        PlayErrorPanel(message: long, onRetry: () {}),
        // 160pt tall is about what an 8K portrait player gets on a small phone.
        size: const Size(320, 160),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('renders without a cover', (tester) async {
    await tester.pumpWidget(
      host(PlayErrorPanel(message: '视频不存在或已被删除', onRetry: () {})),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('the dimmed layer fills the whole player slot', (tester) async {
    // The panel must cover exactly the player area, otherwise the page behind
    // shows through. It expands to its parent rather than honouring width/height
    // as a hard size.
    await tester.pumpWidget(
      host(
        PlayErrorPanel(
          message: 'x',
          onRetry: () {},
          width: 400,
          height: 225,
        ),
        size: const Size(800, 600),
      ),
    );
    final dim = tester.getSize(
      find.descendant(
        of: find.byType(PlayErrorPanel),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(dim.width, 800);
    expect(dim.height, 600);
  });

  testWidgets('never exceeds a tighter parent', (tester) async {
    // The real caller passes the player slot size, which can be smaller than
    // what the panel asks for on a compact layout.
    await tester.pumpWidget(
      host(
        PlayErrorPanel(
          message: 'x',
          onRetry: () {},
          width: 400,
          height: 225,
        ),
        size: const Size(320, 180),
      ),
    );
    final box = tester.getSize(find.byType(PlayErrorPanel));
    expect(box.width, lessThanOrEqualTo(320));
    expect(box.height, lessThanOrEqualTo(180));
    expect(tester.takeException(), isNull);
  });
}