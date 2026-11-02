import 'package:PiliPlus/common/style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dialog width leaves side margins on iPhone Air', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1260, 2736);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    late BoxConstraints constraints;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            constraints = Style.dialogFixedConstraintsFor(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(constraints.maxWidth, 388);
  });
}
