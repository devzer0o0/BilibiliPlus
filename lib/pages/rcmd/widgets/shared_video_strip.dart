import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:material_ui/material_ui.dart';

/// The row of videos people shared over private messages.
///
/// Shown above the recommendation grid and deliberately independent of it: the
/// grid still holds six cards, and a share disappears from here once opened.
class SharedVideoStrip extends StatelessWidget {
  const SharedVideoStrip({
    super.key,
    required this.videos,
    required this.onOpen,
  });

  final List<SharedVideo> videos;
  final ValueChanged<SharedVideo> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Row(
            children: [
              Icon(
                Icons.mark_email_unread_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text('分享给我的视频', style: theme.textTheme.titleSmall),
              const SizedBox(width: 6),
              Text(
                '${videos.length}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: videos.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => _SharedVideoCard(
              video: videos[index],
              onTap: () => onOpen(videos[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _SharedVideoCard extends StatelessWidget {
  const _SharedVideoCard({required this.video, required this.onTap});

  final SharedVideo video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 132,
      // InkWell needs a Material ancestor; the strip can be placed anywhere, so
      // it supplies its own rather than relying on the page.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(10)),
                child: AspectRatio(
                  aspectRatio: 16 / 10,
                  child: video.cover.isEmpty
                      ? ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                        )
                      : Image.network(
                          video.cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Text(
                '来自 ${video.senderName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the video and resolves the cid the page needs.
Future<void> openSharedVideo(SharedVideo video) async {
  final cid = await SearchHttp.ab2c(bvid: video.bvid);
  if (cid == null) return;
  PageUtils.toVideoPage(
    bvid: video.bvid,
    cid: cid,
    cover: video.cover,
    title: video.title,
  );
}
