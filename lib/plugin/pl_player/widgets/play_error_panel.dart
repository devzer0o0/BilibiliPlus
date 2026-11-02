import 'package:flutter/material.dart';

/// Shown in place of the player when playurl fails.
///
/// Before this existed the area rendered nothing, so once the two-second toast
/// faded the user was left staring at a blank rectangle with no idea whether the
/// app was still working. This keeps the cover dimmed behind the reason and
/// offers a retry.
///
/// Lives in its own widget rather than inside the page's state so the layout can
/// be exercised at small and large sizes without a live controller.
class PlayErrorPanel extends StatelessWidget {
  const PlayErrorPanel({
    super.key,
    required this.message,
    this.cover = '',
    required this.onRetry,
    this.width,
    this.height,
  });

  final String message;
  final String cover;
  final VoidCallback onRetry;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (cover.isNotEmpty)
            Image.network(
              cover,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          const ColoredBox(color: Color(0x99000000)),
          Center(
            // A long message in a short player area used to overflow: the
            // column was min-sized and unbounded vertically.
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: onRetry,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
