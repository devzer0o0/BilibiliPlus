// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_lambdas, prefer_const_constructors
import 'dart:async';

import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/pages/setting/ai_profile.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_recommendation_service.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class AiRecommendSettingsPage extends StatefulWidget {
  const AiRecommendSettingsPage({super.key});

  @override
  State<AiRecommendSettingsPage> createState() =>
      _AiRecommendSettingsPageState();
}

class _AiRecommendSettingsPageState extends State<AiRecommendSettingsPage> {
  final _service = AiRecommendationService.instance;
  late AiRecommendSettings _settings;
  late final TextEditingController _want;
  late final TextEditingController _avoid;
  late final TextEditingController _description;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _budget;

  late AiRecommendMode _mode;
  late bool _useHistory;
  late bool _paused;
  late bool _jsonMode;
  late double _exploration;
  late double _threshold;
  late int _retention;

  bool _hasKey = false;
  bool _busy = false;
  bool _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    _settings = _service.settings;
    _want = TextEditingController(text: _settings.wantTags.join('\n'));
    _avoid = TextEditingController(text: _settings.avoidTags.join('\n'));
    _description = TextEditingController(text: _settings.interestDescription);
    _baseUrl = TextEditingController(text: _settings.baseUrl);
    _model = TextEditingController(text: _settings.model);
    _apiKey = TextEditingController();
    _budget = TextEditingController(
      text: _settings.dailyRequestBudget.toString(),
    );
    _mode = _settings.mode;
    _useHistory = _settings.useWatchHistory;
    _paused = _settings.pausedLearning;
    _jsonMode = _settings.jsonMode;
    _exploration = _settings.explorationRatio;
    _threshold = _settings.strictThreshold;
    _retention = _settings.profileRetentionDays;
    _loadKeyState();
  }

  Future<void> _loadKeyState() async {
    final has = await _service.hasApiKey();
    if (!mounted) return;
    setState(() => _hasKey = has);
  }

  @override
  void dispose() {
    _want.dispose();
    _avoid.dispose();
    _description.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _budget.dispose();
    super.dispose();
  }

  AiRecommendSettings _collect() => _settings.copyWith(
    enabled: _settings.enabled,
    mode: _mode,
    wantTags: AiRecommendSettings.parseTags(_want.text),
    avoidTags: AiRecommendSettings.parseTags(_avoid.text),
    interestDescription: _description.text.trim(),
    useWatchHistory: _useHistory,
    pausedLearning: _paused,
    baseUrl: _baseUrl.text.trim(),
    model: _model.text.trim(),
    dailyRequestBudget:
        int.tryParse(_budget.text.trim()) ?? _settings.dailyRequestBudget,
    explorationRatio: _exploration,
    strictThreshold: _threshold,
    profileRetentionDays: _retention,
    jsonMode: _jsonMode,
  );

  Future<void> _save({bool quiet = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = _collect();
    final old = _settings;
    final baseChanged =
        old.baseUrl.trim().replaceAll(RegExp(r'/+$'), '') !=
        next.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseChanged && _hasKey) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('模型服务地址已更改'),
          content: const Text(
            '旧 API Key 不会发送到新地址，保存后会从本机安全存储中删除，需要重新填写。',
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Get.back(result: true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (ok != true) {
        setState(() => _busy = false);
        return;
      }
    }
    try {
      await _service.saveSettings(
        next,
        apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
      );
      _settings = next;
      _apiKey.clear();
      await _loadKeyState();
      if (!quiet) SmartDialog.showToast('已保存');
      if (Get.isRegistered<RcmdController>()) {
        unawaited(Get.find<RcmdController>().onRefresh());
      }
    } on SecretStoreException catch (e) {
      SmartDialog.showToast(e.message);
    } on Object catch (_) {
      SmartDialog.showToast('保存失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probe() async {
    await _save(quiet: true);
    if (!mounted) return;
    setState(() => _busy = true);
    final result = await _service.probe();
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('模型连接测试'),
        content: Text(result.message),
        actions: [
          FilledButton(
            onPressed: () => Get.back(),
            child: Text(result.ok ? '好' : '知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _importHistory() async {
    if (!_useHistory) {
      SmartDialog.showToast('请先开启“使用观看记录学习兴趣”');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入近期观看记录'),
        content: const Text(
          '将读取最近 30 天、最多 200 条视频历史，在本地提取主题并更新兴趣画像；不会把观看历史发送给模型，也不会读取私信或播放地址。观看历史账号必须与当前推荐账号一致。',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final result = await _service.importRecentHistory();
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.failed ? '导入未完成' : '导入完成'),
        content: Text(result.failed ? result.message : result.summary),
        actions: [
          FilledButton(onPressed: () => Get.back(), child: const Text('好')),
        ],
      ),
    );
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除评分缓存'),
        content: const Text('下次刷新会重新向模型评分。画像和明确设置不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.clearScores();
    SmartDialog.showToast('已清除评分缓存');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('AI 推荐筛选'),
        actions: [
          IconButton(
            tooltip: '保存',
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          SwitchListTile(
            value: _settings.enabled,
            onChanged: (value) => setState(
              () => _settings = _settings.copyWith(enabled: value),
            ),
            title: const Text('启用 AI 推荐筛选'),
            subtitle: const Text(
              '默认关闭。关闭时不发请求、不学习，推荐保持原样。',
            ),
            secondary: const Icon(Icons.auto_awesome),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '模式',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('偏好排序（默认）'),
                  selected: _mode == AiRecommendMode.preference,
                  onSelected: (_) =>
                      setState(() => _mode = AiRecommendMode.preference),
                ),
                ChoiceChip(
                  label: const Text('严格精选'),
                  selected: _mode == AiRecommendMode.strict,
                  onSelected: (_) =>
                      setState(() => _mode = AiRecommendMode.strict),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _mode == AiRecommendMode.strict
                  ? '按阈值保留较相关内容；模型未评分的内容不会被误删。内容不足时会有限补充，仍不足则诚实显示少量结果。'
                  : '优先调整顺序，对低相关内容降权；高置信度少看主题可折叠，可查看并恢复。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          const Divider(),
          _tagField(
            controller: _want,
            title: '想看',
            hint: '每行一个关键词或短语，例如：\nFlutter\nNAS 实践',
          ),
          _tagField(
            controller: _avoid,
            title: '少看',
            hint: '这是软偏好，不会绕过标题正则、黑名单等明确规则',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _description,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: '兴趣描述（可选）',
                hintText: '例如：最近想看 Flutter、AI 编程和 NAS 实践，偏好有步骤的教程。',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ),
          SwitchListTile(
            value: _useHistory,
            onChanged: (value) => setState(() => _useHistory = value),
            title: const Text('使用观看记录学习兴趣'),
            subtitle: const Text(
              '默认不开启。开启后从本机有效观看和显式反馈学习；首次启用不会自动读取全部历史。',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('导入近期观看记录'),
            subtitle: const Text('最近 30 天、最多 200 条，仅本地学习'),
            onTap: _busy ? null : _importHistory,
          ),
          const Divider(),
          ExpansionTile(
            initiallyExpanded: _advancedOpen,
            onExpansionChanged: (value) => _advancedOpen = value,
            leading: const Icon(Icons.tune),
            title: const Text('高级设置'),
            subtitle: const Text('模型服务、请求预算、探索与画像管理'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _baseUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '服务地址（OpenAI-compatible）',
                    hintText: 'https://example.com/v1',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: '模型名称',
                    hintText: '手动填写，不依赖 /models 接口',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _apiKey,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: _hasKey ? '已保存在安全存储，留空不修改' : '仅保存在本机安全存储',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: '清除 API Key',
                      onPressed: _hasKey
                          ? () async {
                              await _service.clearApiKey();
                              await _loadKeyState();
                              SmartDialog.showToast('已清除 API Key');
                            }
                          : null,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                ),
              ),
              SwitchListTile(
                value: _jsonMode,
                onChanged: (value) => setState(() => _jsonMode = value),
                title: const Text('请求 JSON 输出模式'),
                subtitle: const Text('服务不支持时关闭；客户端始终严格校验返回 JSON'),
              ),
              ListTile(
                title: const Text('每日请求预算'),
                subtitle: Text('用于限制模型费用；重试也计入'),
                trailing: SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _budget,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
              ),
              ListTile(
                title: const Text('探索比例'),
                subtitle: Text(
                  (_exploration * 100).round().toString() + '% 保留给新主题',
                ),
              ),
              Slider(
                value: _exploration,
                min: 0,
                max: 0.5,
                divisions: 10,
                label: (_exploration * 100).round().toString() + '%',
                onChanged: (value) => setState(() => _exploration = value),
              ),
              ListTile(
                title: const Text('严格精选阈值'),
                subtitle: Text((_threshold * 100).round().toString() + '% 相关性'),
              ),
              Slider(
                value: _threshold,
                min: 0.3,
                max: 0.9,
                divisions: 12,
                onChanged: (value) => setState(() => _threshold = value),
              ),
              ListTile(
                title: const Text('数据保留时间'),
                trailing: DropdownButton<int>(
                  value: _retention,
                  items: const [
                    DropdownMenuItem(value: 30, child: Text('30 天')),
                    DropdownMenuItem(value: 90, child: Text('90 天')),
                    DropdownMenuItem(value: 180, child: Text('180 天')),
                    DropdownMenuItem(value: 365, child: Text('365 天')),
                  ],
                  onChanged: (value) =>
                      setState(() => _retention = value ?? 90),
                ),
              ),
              SwitchListTile(
                value: _paused,
                onChanged: (value) => setState(() => _paused = value),
                title: const Text('暂停学习'),
                subtitle: const Text('保留已有画像，不写入新的观看或反馈'),
              ),
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('管理兴趣画像'),
                subtitle: const Text('查看、删除或重置推测兴趣'),
                onTap: () => Get.to(() => const AiInterestProfilePage()),
              ),
              ListTile(
                leading: const Icon(Icons.cached),
                title: const Text('清除评分缓存'),
                subtitle: const Text('缓存是派生数据，默认不进入备份'),
                onTap: _clearCache,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _probe,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('保存并测试连接'),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              '只发送本次候选的标题、已有简介、分类、时长和你的明确关键词/兴趣摘要；不发送账号、Cookie、私信、播放地址或完整观看历史。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagField({
    required TextEditingController controller,
    required String title,
    required String hint,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: TextField(
      controller: controller,
      maxLines: 4,
      minLines: 2,
      decoration: InputDecoration(
        labelText: title,
        hintText: hint,
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
    ),
  );
}
