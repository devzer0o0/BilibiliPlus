import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Play/pause for either backend.
///
/// It used to take its state from `videoPlayerController!.state`, which does
/// not exist on the native HDR path: the force-unwrap threw inside
/// `initState`, the control bar failed to lay out, and what reached the screen
/// was an overflow banner instead of a player. State now comes from the shared
/// snapshot, which both backends publish.
class PlayOrPauseButton extends StatelessWidget {
  const PlayOrPauseButton({super.key, required this.plPlayerController});

  final PlPlayerController plPlayerController;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (plPlayerController.playerStatus.isPlaying) {
            plPlayerController.pause();
          } else {
            plPlayerController.play();
          }
        },
        child: Center(
          // The status is read inside the Obx, and it is now an observable
          // (PlPlayerController.playerStatus is backed by an Rx). Reading a
          // plain field here made the dependency list empty: GetX logged
          // "improper use of a GetX", the build threw, and the button was drawn
          // as a 42x34 grey error box instead of an icon.
          child: Obx(() {
            final playing = plPlayerController.playerStatus.isPlaying;
            return AnimatedIcon(
              semanticLabel: playing ? '暂停' : '播放',
              progress: AlwaysStoppedAnimation<double>(playing ? 1 : 0),
              icon: AnimatedIcons.play_pause,
              color: Colors.white,
              size: 20,
            );
          }),
        ),
      ),
    );
  }
}
