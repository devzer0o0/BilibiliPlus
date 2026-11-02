import 'dart:io';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/pages/setting/widgets/multi_select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/normal_item.dart';
import 'package:PiliPlus/pages/setting/widgets/ordered_multi_select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

import '../support/hive_test_env.dart';

/// iPhone Air: 420 x 912 logical points at DPR 3 (1260 x 2736 pixels).
const iphoneAirPhysical = Size(1260, 2736);
const iphoneAirLandscapePhysical = Size(2736, 1260);
const iphoneAirWidth = 420.0;
const iphoneAirHeight = 912.0;

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await setUpTestStorage();
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  /// The app runs on material_ui's MaterialApp; its delegates resolve the
  /// material_ui MaterialLocalizations that AlertDialog needs.
  Widget testApp(Widget home) => MaterialApp(
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
    home: home,
  );

  void useViewport(WidgetTester tester, Size physical) {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = physical;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  /// The rect of the dialog surface itself (the AlertDialog widget spans the
  /// whole route, so measure the Material that paints the dialog box).
  Rect dialogRect(WidgetTester tester) {
    final material = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Material),
    );
    return tester.getRect(material.first);
  }

  testWidgets('iPhone Air reports the audited logical viewport', (
    tester,
  ) async {
    useViewport(tester, iphoneAirPhysical);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(size.width, iphoneAirWidth);
    expect(size.height, iphoneAirHeight);
  });

  testWidgets('dialogs keep side margins in portrait and landscape', (
    tester,
  ) async {
    for (final physical in [iphoneAirPhysical, iphoneAirLandscapePhysical]) {
      useViewport(tester, physical);
      final width = physical.width / 3;
      late BoxConstraints constraints;
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) {
              constraints = Style.dialogFixedConstraintsFor(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(constraints.maxWidth, lessThan(width));
      expect(constraints.maxWidth, lessThanOrEqualTo(420));
      expect(width - constraints.maxWidth, greaterThanOrEqualTo(32));
    }
  });

  testWidgets('quality select dialog fits the portrait viewport', (tester) async {
    useViewport(tester, iphoneAirPhysical);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Builder(
            builder: (context) => AlertDialog(
              constraints: Style.dialogFixedConstraintsFor(context),
              title: const Text('清晰度'),
              content: const SizedBox(height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final rect = dialogRect(tester);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(iphoneAirWidth));
    expect(rect.width, lessThanOrEqualTo(388));
  });

  testWidgets('codec order dialog fits the portrait viewport', (tester) async {
    useViewport(tester, iphoneAirPhysical);
    await tester.pumpWidget(
      testApp(
        OrderedMultiSelectDialog<String>(
          initValues: const ['AV1', 'HEVC'],
          title: const Text('首选解码格式'),
          values: const {'AV1': 'AV1', 'HEVC': 'HEVC', 'AVC': 'AVC'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('AV1'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    final rect = dialogRect(tester);
    expect(rect.width, lessThanOrEqualTo(iphoneAirWidth));
  });

  testWidgets('settings rows fit without truncating the trailing value', (
    tester,
  ) async {
    useViewport(tester, iphoneAirPhysical);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ListView(
            children: [
              NormalItem(
                title: '首选解码格式',
                subtitle: '首选解码格式：AV1,HEVC,AVC，AV1/HEVC 均由 VideoToolbox 硬解',
                getTrailing: (theme) => Text(
                  'AV1,HEVC,AVC',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              NormalItem(
                title: '硬解模式',
                subtitle: '当前：videotoolbox,auto-safe（此项即mpv的--hwdec）',
                getTrailing: (theme) => Text(
                  'videotoolbox,auto-safe',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final label in ['首选解码格式', '硬解模式']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(iphoneAirWidth));
    }
  });

  testWidgets('multi select dialog fits the narrow viewport', (tester) async {
    useViewport(tester, iphoneAirPhysical);
    await tester.pumpWidget(
      testApp(
        MultiSelectDialog<int>(
          title: '选择下载清晰度',
          values: const {
            1: '4K 超清（需要大会员）',
            2: '1080P60 高帧率',
            3: '1080P 高清',
          },
          initValues: const {1, 3},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final rect = dialogRect(tester);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(iphoneAirWidth));
  });

  testWidgets('long codec labels do not overflow a narrow viewport', (
    tester,
  ) async {
    useViewport(tester, iphoneAirPhysical);
    await tester.pumpWidget(
      testApp(
        SelectDialog<int>(
          title: '首选解码格式：AV1,HEVC,AVC',
          value: 1,
          values: const [
            (1, 'AV1 av01.0.08M.08 VideoToolbox 硬件解码，功耗更低'),
            (2, 'HEVC hvc1.1.6.L120.90 VideoToolbox 硬件解码，兼容性更好'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Title plus one option mention HEVC; both must render inside the dialog.
    expect(find.textContaining('HEVC'), findsWidgets);
    expect(find.text('HEVC hvc1.1.6.L120.90 VideoToolbox 硬件解码，兼容性更好'), findsOneWidget);
    final rect = dialogRect(tester);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(iphoneAirWidth));
  });
}
