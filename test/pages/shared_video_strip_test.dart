import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/pages/rcmd/widgets/shared_video_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The strip only appears when there is something to show; its layout must hold
/// at the narrow widths a phone gives it, and a tap must report the video.
void main() {
  SharedVideo video(String bvid, {String sender = 'StepGo'}) => SharedVideo(
    bvid: bvid,
    title: '一个比较长的视频标题，用来验证两行省略是否生效',
    senderName: sender,
    senderId: 1,
    cover: '',
  );

  Widget host(Widget child, {Size size = const Size(420, 400)}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: size.width,
        height: size.height,
        child: child,
      ),
    ),
  );

  testWidgets('shows the header and one card per video', (tester) async {
    await tester.pumpWidget(
      host(
        SharedVideoStrip(
          videos: [video('BV1'), video('BV2')],
          onOpen: (_) {},
        ),
      ),
    );
    expect(find.text('分享给我的视频'), findsOneWidget);
    expect(find.text('一个比较长的视频标题，用来验证两行省略是否生效'), findsNWidgets(2));
  });

  testWidgets('attributes each card to its sender', (tester) async {
    await tester.pumpWidget(
      host(
        SharedVideoStrip(
          videos: [video('BV1', sender: 'StepGo')],
          onOpen: (_) {},
        ),
      ),
    );
    expect(find.text('来自 StepGo'), findsOneWidget);
  });

  testWidgets('tapping a card reports that video', (tester) async {
    SharedVideo? opened;
    await tester.pumpWidget(
      host(
        SharedVideoStrip(
          videos: [video('BV1'), video('BV2')],
          onOpen: (v) => opened = v,
        ),
      ),
    );
    await tester.tap(find.text('来自 StepGo').first);
    await tester.pump();
    expect(opened?.bvid, 'BV1');
  });

  testWidgets('does not overflow a narrow phone', (tester) async {
    await tester.pumpWidget(
      host(
        SharedVideoStrip(
          videos: [video('BV1'), video('BV2'), video('BV3')],
          onOpen: (_) {},
        ),
        size: const Size(320, 300),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
