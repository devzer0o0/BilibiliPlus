import 'package:PiliPlus/common/widgets/liquid_glass_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/liquid_glass_surface.dart';
import 'package:PiliPlus/common/widgets/main_layout.dart';

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _home = LiquidGlassDestination(
  label: '首页',
  icon: Icon(Icons.home_outlined),
  selectedIcon: Icon(Icons.home_rounded),
);
const _dynamics = LiquidGlassDestination(
  label: '动态',
  icon: Icon(Icons.smart_display_outlined),
  selectedIcon: Icon(Icons.smart_display),
);
const _mine = LiquidGlassDestination(
  label: '我的',
  icon: Icon(Icons.person_rounded),
  selectedIcon: Icon(Icons.person_rounded),
  isAvatar: true,
);

Widget _app(
  Widget child, {
  Size size = const Size(420, 912),
  EdgeInsets padding = const EdgeInsets.only(top: 47, bottom: 34),
  bool disableAnimations = false,
  double devicePixelRatio = 3,
}) {
  return MediaQuery(
    data: MediaQueryData(
      size: size,
      padding: padding,
      viewPadding: padding,
      devicePixelRatio: devicePixelRatio,
      disableAnimations: disableAnimations,
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Material(child: child),
    ),
  );
}

void _setView(WidgetTester tester, Size size, {double dpr = 3}) {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}

Rect _indicator(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('liquid-nav-indicator')));

double _cellCenter(int index, double width, int count) =>
    width / count * index + width / count / 2;

void main() {
  testWidgets('taps report the index and the pill follows the controller', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    final selected = <int>[];
    var index = 0;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => LiquidGlassNavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) {
              selected.add(i);
              setState(() => index = i);
            },
            bottomInset: 34,
            destinations: const [_home, _dynamics, _mine],
          ),
        ),
      ),
    );

    final surface = tester.getRect(find.byType(LiquidGlassSurface));
    expect(surface.width, LiquidGlassNavigationBar.shellWidthFor(420));
    expect(surface.height, kLiquidNavBarHeight);

    for (final i in [1, 2, 0]) {
      await tester.tap(find.byKey(ValueKey('liquid-nav-item-$i')));
      await tester.pumpAndSettle();
      expect(selected.last, i);
      final expected = surface.left + _cellCenter(i, surface.width, 3);
      expect(_indicator(tester).center.dx, closeTo(expected, 0.6));
    }
  });

  testWidgets('rapid taps settle on the last selection', (tester) async {
    _setView(tester, const Size(420, 912));
    var index = 0;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => LiquidGlassNavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => setState(() => index = i),
            bottomInset: 34,
            destinations: const [_home, _dynamics, _mine],
          ),
        ),
      ),
    );
    final surface = tester.getRect(find.byType(LiquidGlassSurface));

    await tester.tap(find.byKey(const ValueKey('liquid-nav-item-2')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const ValueKey('liquid-nav-item-1')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const ValueKey('liquid-nav-item-0')));
    await tester.pumpAndSettle();

    expect(index, 0);
    expect(
      _indicator(tester).center.dx,
      closeTo(surface.left + _cellCenter(0, surface.width, 3), 0.6),
    );
  });

  testWidgets('reordered destinations keep labels and callbacks aligned', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    final tapped = <int>[];
    await tester.pumpWidget(
      _app(
        LiquidGlassNavigationBar(
          selectedIndex: 0,
          onDestinationSelected: tapped.add,
          bottomInset: 34,
          destinations: const [_mine, _dynamics, _home],
        ),
      ),
    );

    final semantics = tester.ensureSemantics();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('liquid-nav-item-0')))
          .label,
      '我的',
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('liquid-nav-item-2')))
          .label,
      '首页',
    );
    semantics.dispose();
    await tester.tap(find.byKey(const ValueKey('liquid-nav-item-0')));
    expect(tapped, [0]);
    await tester.tap(find.byKey(const ValueKey('liquid-nav-item-2')));
    expect(tapped, [0, 2]);
  });

  testWidgets('a hidden destination is not laid out and single entry works', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    await tester.pumpWidget(
      _app(
        LiquidGlassNavigationBar(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          bottomInset: 34,
          destinations: const [_home, _mine],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('liquid-nav-item-2')), findsNothing);
    final width = tester.getRect(find.byType(LiquidGlassSurface)).width;
    // Never wider than the reference pill, even when a cell is wider than 84.
    expect(_indicator(tester).width, kLiquidNavIndicatorWidth);
    expect(_indicator(tester).center.dx, closeTo(30 + width / 4, 0.6));

    await tester.pumpWidget(
      _app(
        LiquidGlassNavigationBar(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          bottomInset: 34,
          destinations: const [_home],
        ),
      ),
    );
    expect(_indicator(tester).width, kLiquidNavIndicatorWidth);
    expect(
      _indicator(tester).center.dx,
      closeTo(tester.getRect(find.byType(LiquidGlassSurface)).center.dx, 0.6),
    );
  });

  testWidgets('badge is painted and the avatar falls back safely', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            const LiquidGlassAvatar(isLoggedIn: false, face: ''),
            const LiquidGlassAvatar(isLoggedIn: true, face: ''),
            LiquidGlassAvatar(
              isLoggedIn: true,
              face: 'https://example.invalid/a.jpg',
              imageBuilder: (context, url) =>
                  Text('avatar:$url', key: const Key('fake-avatar')),
            ),
          ],
        ),
      ),
    );
    expect(find.byIcon(Icons.person_rounded), findsNWidgets(2));
    expect(find.byKey(const Key('fake-avatar')), findsOneWidget);

    await tester.pumpWidget(
      _app(
        LiquidGlassNavigationBar(
          selectedIndex: 1,
          onDestinationSelected: (_) {},
          bottomInset: 34,
          destinations: const [
            _home,
            LiquidGlassDestination(
              label: '动态',
              icon: Icon(Icons.smart_display_outlined),
              selectedIcon: Icon(Icons.smart_display),
              badge: SizedBox(key: Key('dyn-badge'), width: 8, height: 8),
            ),
            _mine,
          ],
        ),
      ),
    );
    expect(find.byKey(const Key('dyn-badge')), findsOneWidget);
  });

  testWidgets('glass degrades to blur and solid without the shader', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    await tester.pumpWidget(
      _app(
        const LiquidGlassSurface(
          width: 360,
          height: 52,
          radius: 26,
          mode: LiquidGlassMode.blur,
          child: SizedBox.expand(),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pumpWidget(
      _app(
        const LiquidGlassSurface(
          width: 360,
          height: 52,
          radius: 26,
          mode: LiquidGlassMode.solid,
          child: SizedBox.expand(),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ColoredBox), findsWidgets);
  });

  testWidgets('auto mode never throws when the shader is unavailable', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    await tester.pumpWidget(
      _app(
        const LiquidGlassSurface(
          width: 360,
          height: 52,
          radius: 26,
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.byType(LiquidGlassSurface), findsOneWidget);
  });

  testWidgets('MainLayout counts the bottom inset exactly once', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    await tester.pumpWidget(
      _app(
        MainLayout(
          sideBar: null,
          body: Container(key: const Key('body'), color: Colors.red),
          bottomNav: LiquidGlassNavigationBar(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            bottomInset: 34,
            destinations: const [_home, _dynamics, _mine],
          ),
        ),
      ),
    );

    final bar = tester.getRect(find.byType(LiquidGlassNavigationBar));
    final capsule = tester.getRect(find.byType(LiquidGlassSurface));
    final body = tester.getRect(find.byKey(const Key('body')));

    expect(bar.height, 34 + kLiquidNavBarHeight);
    expect(bar.bottom, 912);
    expect(capsule.bottom, 912 - 34);
    expect(capsule.top, 912 - 34 - kLiquidNavBarHeight);
    expect(capsule.width, LiquidGlassNavigationBar.shellWidthFor(420));
    expect(capsule.center.dx, 210);
    // The body keeps the full height: content scrolls under the glass.
    expect(body.height, 912);
  });

  testWidgets('no inset, small screen and scaled UI stay proportional', (
    tester,
  ) async {
    Widget shell({
      required double inset,
      required Size size,
      required EdgeInsets padding,
      double dpr = 3,
    }) => _app(
      MainLayout(
        sideBar: null,
        body: const SizedBox.expand(),
        bottomNav: LiquidGlassNavigationBar(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          bottomInset: inset,
          destinations: const [_home, _dynamics, _mine],
        ),
      ),
      size: size,
      padding: padding,
      devicePixelRatio: dpr,
    );

    _setView(tester, const Size(420, 912));
    await tester.pumpWidget(
      shell(
        inset: 0,
        size: const Size(420, 912),
        padding: EdgeInsets.zero,
      ),
    );
    expect(
      tester.getRect(find.byType(LiquidGlassSurface)).bottom,
      912 - kLiquidNavMinBottomGap,
    );

    _setView(tester, const Size(320, 640));
    await tester.pumpWidget(
      shell(
        inset: 0,
        size: const Size(320, 640),
        padding: EdgeInsets.zero,
      ),
    );
    final small = tester.getRect(find.byType(LiquidGlassSurface));
    expect(small.width, 320 - 2 * kLiquidNavBarSideMargin);
    expect(_indicator(tester).width, closeTo(small.width / 3 - 16, 0.01));
    expect(small.bottom, 640 - kLiquidNavMinBottomGap);

    // uiScale shrinks the logical size while the physical pixels stay the same.
    // Geometry must follow the logical numbers and must not double-scale.
    _setView(tester, const Size(350, 760), dpr: 3.6);
    await tester.pumpWidget(
      shell(
        inset: 28,
        size: const Size(350, 760),
        padding: const EdgeInsets.only(top: 39, bottom: 28),
        dpr: 3.6,
      ),
    );
    final scaled = tester.getRect(find.byType(LiquidGlassSurface));
    expect(scaled.width, 290);
    expect(scaled.bottom, 760 - 28);
  });

  testWidgets('whitespace does not swallow taps and a hidden bar is inert', (
    tester,
  ) async {
    _setView(tester, const Size(420, 912));
    var bodyTaps = 0;
    var viewInsets = EdgeInsets.zero;

    Widget build() => _app(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(420, 912),
          padding: const EdgeInsets.only(top: 47, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
          viewInsets: viewInsets,
          devicePixelRatio: 3,
        ),
        child: MainLayout(
          sideBar: null,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => bodyTaps++,
            child: const SizedBox.expand(),
          ),
          bottomNav: LiquidGlassNavigationBar(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            bottomInset: 34,
            destinations: const [_home, _dynamics, _mine],
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    // Left of the capsule: the bar's own box is transparent there.
    await tester.tapAt(const Offset(6, 880));
    expect(bodyTaps, 1);
    // Inside the capsule the destination wins.
    await tester.tapAt(const Offset(210, 870));
    expect(bodyTaps, 1);

    // Keyboard open: the bar is gone and its area belongs to the page again.
    viewInsets = const EdgeInsets.only(bottom: 320);
    await tester.pumpWidget(build());
    expect(find.byType(LiquidGlassSurface), findsNothing);
    await tester.tapAt(const Offset(210, 870));
    expect(bodyTaps, 2);
  });

  testWidgets('reduce motion lands the pill without animating', (tester) async {
    _setView(tester, const Size(420, 912));
    var index = 0;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => LiquidGlassNavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => setState(() => index = i),
            bottomInset: 34,
            destinations: const [_home, _dynamics, _mine],
          ),
        ),
        disableAnimations: true,
      ),
    );
    final surface = tester.getRect(find.byType(LiquidGlassSurface));
    await tester.tap(find.byKey(const ValueKey('liquid-nav-item-2')));
    await tester.pump();
    expect(
      _indicator(tester).center.dx,
      closeTo(surface.left + _cellCenter(2, surface.width, 3), 0.6),
    );
  });

  testWidgets('semantics expose label and selection', (tester) async {
    _setView(tester, const Size(420, 912));
    await tester.pumpWidget(
      _app(
        LiquidGlassNavigationBar(
          selectedIndex: 1,
          onDestinationSelected: (_) {},
          bottomInset: 34,
          destinations: const [_home, _dynamics, _mine],
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(
      find.byKey(const ValueKey('liquid-nav-item-1')),
    );
    expect(node.label, '动态');
    expect(node.flagsCollection.isSelected, ui.Tristate.isTrue);
    semantics.dispose();
  });
}
