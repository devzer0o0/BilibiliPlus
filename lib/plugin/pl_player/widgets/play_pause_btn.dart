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
          child: Obx(
            () => AnimatedIcon(
              semanticLabel: plPlayerController.playerStatus.isPlaying
                  ? '暂停'
                  : '播放',
              progress: AlwaysStoppedAnimation<double>(
                plPlayerController.playerStatus.isPlaying ? 1 : 0,
              ),
              icon: AnimatedIcons.play_pause,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
