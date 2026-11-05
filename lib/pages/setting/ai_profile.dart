// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_lambdas, prefer_const_constructors
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_recommendation_service.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Manage only inferred interests. Explicit keywords live in settings and are
/// never listed here as if the model owned them.
class AiInterestProfilePage extends StatefulWidget {
  const AiInterestProfilePage({super.key});

  @override
  State<AiInterestProfilePage> createState() => _AiInterestProfilePageState();
}

class _AiInterestProfilePageState extends State<AiInterestProfilePage> {
  InterestProfile? _profile;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await AiRecommendationService.instance.profile();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '读取本地画像失败';
        _loading = false;
      });
    }
  }

  Future<void> _delete(String id) async {
    await AiRecommendationService.instance.deleteTopic(id);
    await _load();
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置推测兴趣'),
        content: const Text(
          '这会删除本账号的推测主题、作者偏好和反馈记录。你明确设置的关键词不会改变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AiRecommendationService.instance.resetProfile();
    await _load();
    SmartDialog.showToast('已重置推测兴趣');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _profile;
    return SimpleScaffold(
      appBar: AppBar(title: const Text('管理兴趣画像')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 100),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '这些主题由本地观看和反馈推测，可随时删除。明确填写的关键词与兴趣描述不会被改写，也不会自动过期。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                if (profile == null || profile.visibleTopics.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.auto_awesome_outlined),
                    title: Text('还没有推测兴趣'),
                    subtitle: Text('开启学习并观看视频，或用“多看一些/少看一些”反馈后出现'),
                  )
                else
                  ...profile.visibleTopics.map(
                    (topic) => ListTile(
                      leading: Icon(
                        topic.score >= 0
                            ? Icons.thumb_up_outlined
                            : Icons.thumb_down_outlined,
                      ),
                      title: Text(topic.label),
                      subtitle: Text(
                        '权重 ' +
                            topic.score.toStringAsFixed(2) +
                            ' · 来源 ' +
                            _sourceLabel(topic.source) +
                            ' · 命中 ' +
                            topic.hits.toString(),
                      ),
                      trailing: IconButton(
                        tooltip: '删除该推测兴趣',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(topic.id),
                      ),
                    ),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('学习记录'),
                  subtitle: Text(
                    '本地保留 ' +
                        (profile?.events.length ?? 0).toString() +
                        ' 条（最多 90 天 / 1000 条）',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.feedback_outlined),
                  title: const Text('反馈记录'),
                  subtitle: Text(
                    '可撤销最近一次；共 ' +
                        (profile?.feedbacks.length ?? 0).toString() +
                        ' 条',
                  ),
                  trailing: TextButton(
                    onPressed: profile == null || profile.feedbacks.isEmpty
                        ? null
                        : () async {
                            final ok = await AiRecommendationService.instance
                                .undoLastFeedback();
                            if (ok) {
                              await _load();
                              SmartDialog.showToast('已撤销最近一次反馈');
                            }
                          },
                    child: const Text('撤销'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.tonalIcon(
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('重置推测兴趣'),
                  ),
                ),
              ],
            ),
    );
  }

  static String _sourceLabel(String source) => switch (source) {
    'feedback' => '显式反馈',
    'watch' => '观看行为',
    _ => '本地学习',
  };
}
