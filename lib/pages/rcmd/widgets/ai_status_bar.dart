// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_lambdas, prefer_const_constructors
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Compact entry point above the grid. It exposes state the user can act on,
/// never internal class names, raw model JSON or signatures.
class AiStatusBar extends StatelessWidget {
  const AiStatusBar({super.key, required this.controller});

  final RcmdController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!controller.aiEnabled) return const SizedBox.shrink();
      final page = controller.aiPage.value;
      final theme = Theme.of(context);
      final mode = controller.aiSettings.mode;
      final status = page?.status ?? AiFeedStatus.localRules;
      final blocked = controller.aiBlockedReason.value;
      final lateReady = controller.aiNewRankingReady.value;
      final latePending =
          lateReady &&
          (status == AiFeedStatus.unavailable ||
              status == AiFeedStatus.localRules);
      // When the background pass never scored anything, the reason is the only
      // thing worth showing: "local rules" alone reads like the feature is off.
      final blockedShown =
          !latePending &&
          blocked.isNotEmpty &&
          (status == AiFeedStatus.unavailable ||
              status == AiFeedStatus.localRules ||
              status == AiFeedStatus.budgetExhausted);
      final statusLabel = latePending
          ? 'AI 排序已就绪 · 点应用'
          : blockedShown
          ? blocked
          : status.label;
      final color = latePending
          ? theme.colorScheme.primary
          : blockedShown
          ? theme.colorScheme.error
          : switch (status) {
              AiFeedStatus.active => theme.colorScheme.primary,
              AiFeedStatus.cached => theme.colorScheme.tertiary,
              AiFeedStatus.unavailable ||
              AiFeedStatus.budgetExhausted => theme.colorScheme.error,
              _ => theme.colorScheme.outline,
            };
      return Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.6,
          ),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _showSheet(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, size: 15, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'AI · ' + mode.label + ' · ' + statusLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: color,
                      ),
                    ),
                  ),
                  if (controller.aiFoldedCount > 0)
                    Text(
                      '折叠 ' + controller.aiFoldedCount.toString(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  if (controller.aiNewRankingReady.value) ...[
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: controller.applyLateAiRanking,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 28),
                      ),
                      child: const Text('应用'),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  void _showSheet(BuildContext context) {
    final page = controller.aiPage.value;
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI · ' + controller.aiSettings.mode.label,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                (page?.status.label ?? '准备中') +
                    (page?.statusDetail.isNotEmpty == true
                        ? '：' + page!.statusDetail
                        : ''),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              if (controller.aiBlockedReason.value.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '后台评分未执行：' + controller.aiBlockedReason.value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (page != null) ...[
                const SizedBox(height: 10),
                Text(
                  '上游 ' +
                      page.originalCount.toString() +
                      ' 条 · 保留 ' +
                      page.keptCount.toString() +
                      ' 条 · AI 新评分 ' +
                      page.freshScores.toString() +
                      ' 条 · 缓存 ' +
                      page.cacheHits.toString() +
                      ' 条',
                  style: theme.textTheme.labelSmall,
                ),
                if (page.strictDropped > 0)
                  Text(
                    '严格精选筛除 ' + page.strictDropped.toString() + ' 条',
                    style: theme.textTheme.labelSmall,
                  ),
                if (page.exploreCount > 0)
                  Text(
                    '其中探索位 ' + page.exploreCount.toString() + ' 条',
                    style: theme.textTheme.labelSmall,
                  ),
                if (page.requestsToday > 0)
                  Text(
                    '今日模型请求 ' + page.requestsToday.toString() + ' 次',
                    style: theme.textTheme.labelSmall,
                  ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      controller.openAiSettings();
                    },
                    icon: const Icon(Icons.tune),
                    label: const Text('调整兴趣'),
                  ),
                  if (controller.aiNewRankingReady.value)
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        controller.applyLateAiRanking();
                      },
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('应用当前页 AI 排序'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      controller.onRefresh();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新推荐'),
                  ),
                  if (controller.aiFoldedCount > 0)
                    OutlinedButton.icon(
                      onPressed: () {
                        controller.restoreFolded();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.unfold_more),
                      label: Text(
                        '显示折叠的 ' + controller.aiFoldedCount.toString() + ' 条',
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
