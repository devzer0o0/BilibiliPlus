import 'dart:convert';

import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/models/backup/backup_record.dart';
import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:PiliPlus/utils/backup/backup_registry.dart';
import 'package:PiliPlus/utils/backup/backup_service.dart';
import 'package:PiliPlus/utils/backup/restore_planner.dart';
import 'package:PiliPlus/utils/backup/s3_object_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class S3BackupPage extends StatefulWidget {
  const S3BackupPage({super.key});

  @override
  State<S3BackupPage> createState() => _S3BackupPageState();
}

class _S3BackupPageState extends State<S3BackupPage> {
  final _service = BackupService.instance;
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _bucket = TextEditingController();
  final _region = TextEditingController();
  final _prefix = TextEditingController();
  final _accessKey = TextEditingController();
  final _secretKey = TextEditingController();
  final _sessionToken = TextEditingController();
  final _timeout = TextEditingController();
  final _interval = TextEditingController();
  final _retain = TextEditingController();

  late S3AddressingMode _addressing;
  late BackupSelection _selection;
  late bool _autoEnabled;
  late bool _wifiOnly;
  bool _busy = false;
  bool _loadingSnapshots = false;
  bool _hasCredentials = false;
  String? _keyId;
  List<BackupSnapshotRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    final config = _service.config;
    _name.text = config.displayName;
    _endpoint.text = config.endpoint;
    _bucket.text = config.bucket;
    _region.text = config.region;
    _prefix.text = config.prefix;
    _timeout.text = config.timeoutSeconds.toString();
    _interval.text = config.autoIntervalHours.toString();
    _retain.text = config.retainAutoSnapshots.toString();
    _addressing = config.addressing;
    _selection = config.selection;
    _autoEnabled = config.autoEnabled;
    _wifiOnly = config.autoWifiOnly;
    _loadState();
  }

  Future<void> _loadState() async {
    final hasCredentials = await _service.hasCredentials();
    final keyId = await _service.recoveryKeyId();
    if (!mounted) return;
    setState(() {
      _hasCredentials = hasCredentials;
      _keyId = keyId;
    });
    if (hasCredentials) {
      await _refreshSnapshots(silent: true);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _endpoint,
      _bucket,
      _region,
      _prefix,
      _accessKey,
      _secretKey,
      _sessionToken,
      _timeout,
      _interval,
      _retain,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  S3BackupConfig _collectConfig() => S3BackupConfig(
    displayName: _name.text.trim(),
    endpoint: _endpoint.text.trim(),
    bucket: _bucket.text.trim(),
    region: _region.text.trim(),
    prefix: _prefix.text.trim(),
    addressing: _addressing,
    timeoutSeconds: int.tryParse(_timeout.text.trim()) ?? 20,
    autoEnabled: _autoEnabled,
    autoWifiOnly: _wifiOnly,
    autoIntervalHours: int.tryParse(_interval.text.trim()) ?? 6,
    retainAutoSnapshots: int.tryParse(_retain.text.trim()) ?? 20,
    selection: _selection,
  );

  Future<bool> _save({bool quiet = false}) async {
    final config = _collectConfig();
    final error = config.validationError();
    if (error != null) {
      SmartDialog.showToast(error);
      return false;
    }
    setState(() => _busy = true);
    try {
      await _service.saveConfig(config);
      if (_accessKey.text.trim().isNotEmpty ||
          _secretKey.text.trim().isNotEmpty) {
        if (_accessKey.text.trim().isEmpty || _secretKey.text.trim().isEmpty) {
          SmartDialog.showToast('Access Key 与 Secret Key 需要同时填写');
          return false;
        }
        await _service.saveCredentials(
          accessKeyId: _accessKey.text.trim(),
          secretAccessKey: _secretKey.text.trim(),
          sessionToken: _sessionToken.text.trim(),
        );
        _accessKey.clear();
        _secretKey.clear();
        _sessionToken.clear();
        _hasCredentials = true;
      }
      if (!quiet) SmartDialog.showToast('S3 配置已保存');
      return true;
    } on Object catch (_) {
      SmartDialog.showToast('保存失败');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    if (!await _save(quiet: true)) return;
    setState(() => _busy = true);
    try {
      final report = await _service.testConnection();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('连接测试'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _resultRow('读取', report.canRead),
              _resultRow('写入', report.canWrite),
              _resultRow('删除', report.canDelete),
              if (report.message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(report.message),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Get.back(),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } on S3Exception catch (e) {
      SmartDialog.showToast(_s3Message(e));
    } on Object catch (_) {
      SmartDialog.showToast('连接测试失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _resultRow(String label, bool ok) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.cancel_outlined,
          size: 18,
          color: ok ? Colors.green : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 8),
        Text(label + (ok ? '正常' : '不可用')),
      ],
    ),
  );

  Future<void> _showRecoveryCode() async {
    setState(() => _busy = true);
    try {
      final info = await _service.ensureRecoveryKey();
      if (!mounted) return;
      setState(() => _keyId = info.keyId);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('备份恢复码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '恢复码等同于解密钥匙。请保存到密码管理器。丢失且旧设备不可用时，快照无法恢复。',
              ),
              const SizedBox(height: 10),
              SelectableText(
                info.code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                '密钥标识：' + info.keyId,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: info.code));
                SmartDialog.showToast('恢复码已复制');
              },
              child: const Text('复制'),
            ),
            FilledButton(
              onPressed: () => Get.back(),
              child: const Text('我已保存'),
            ),
          ],
        ),
      );
    } on Object catch (_) {
      SmartDialog.showToast('无法访问安全存储');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importRecoveryCode() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入恢复码'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'PPB1-...',
            border: OutlineInputBorder(),
          ),
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
    try {
      final info = await _service.importRecoveryCode(controller.text);
      if (!mounted) return;
      setState(() => _keyId = info.keyId);
      SmartDialog.showToast('恢复码已导入');
    } on Object catch (e) {
      SmartDialog.showToast(
        e is Exception ? '恢复码无效或校验失败' : '恢复码无效',
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _backupNow() async {
    if (!await _save(quiet: true)) return;
    if (await _service.recoveryKeyId() == null) {
      await _showRecoveryCode();
    }
    setState(() => _busy = true);
    final result = await _service.backupNow();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.status == BackupTaskStatus.done) {
      SmartDialog.showToast('备份完成并已回读校验');
      await _refreshSnapshots(silent: true);
    } else if (result.status == BackupTaskStatus.failed) {
      SmartDialog.showToast(result.message);
    }
  }

  Future<void> _refreshSnapshots({bool silent = false}) async {
    if (_loadingSnapshots) return;
    setState(() => _loadingSnapshots = true);
    try {
      final records = await _service.listSnapshots();
      if (!mounted) return;
      setState(() => _records = records);
    } on S3Exception catch (e) {
      if (!silent) SmartDialog.showToast(_s3Message(e));
    } on Object catch (_) {
      if (!silent) SmartDialog.showToast('读取快照列表失败');
    } finally {
      if (mounted) setState(() => _loadingSnapshots = false);
    }
  }

  Future<void> _delete(BackupSnapshotRecord record) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除快照'),
        content: Text(
          '确定删除 ' + _formatTime(record.createdAt) + ' 的快照？该操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteSnapshot(record);
      await _refreshSnapshots();
      SmartDialog.showToast('已删除');
    } on S3Exception catch (e) {
      SmartDialog.showToast(_s3Message(e));
    }
  }

  Future<void> _cleanup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理旧自动快照'),
        content: const Text(
          '只清理本设备、当前备份集内由自动备份创建的旧快照；手动快照和其他设备不删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final count = await _service.cleanupAutoSnapshots();
      await _refreshSnapshots();
      SmartDialog.showToast('已清理 ' + count.toString() + ' 个自动快照');
    } on S3Exception catch (e) {
      SmartDialog.showToast(_s3Message(e));
    }
  }

  Future<void> _restore(BackupSnapshotRecord record) async {
    setState(() => _busy = true);
    try {
      final archive = await _service.inspectSnapshot(record.key);
      if (!mounted) return;
      final selected = <String>{...archive.categories.keys};
      var mergeLists = false;
      RestorePreview? preview = await _service.preview(
        record.key,
        selection: BackupSelection(archive.categories.keys.toSet()),
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheetState) {
            final plan = preview?.plan;
            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.9,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '恢复预览',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '快照 ' +
                            record.snapshotId +
                            ' · ' +
                            _formatTime(record.createdAt),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: plan == null
                            ? const Center(child: CircularProgressIndicator())
                            : ListView(
                                children: [
                                  ...archive.categories.keys.map(
                                    (id) => CheckboxListTile(
                                      value: selected.contains(id),
                                      title: Text(
                                        BackupRegistry.byId(id)?.label ?? id,
                                      ),
                                      subtitle: Text(
                                        _categorySummary(plan, id),
                                      ),
                                      onChanged: (value) => setSheetState(() {
                                        if (value == true) {
                                          selected.add(id);
                                        } else {
                                          selected.remove(id);
                                        }
                                      }),
                                    ),
                                  ),
                                  SwitchListTile(
                                    value: mergeLists,
                                    title: const Text('名单合并去重'),
                                    subtitle: const Text('关闭时按快照内容替换'),
                                    onChanged: (value) async {
                                      setSheetState(() => mergeLists = value);
                                      final next = await _service.preview(
                                        record.key,
                                        selection: BackupSelection(selected),
                                        mergeLists: value,
                                      );
                                      setSheetState(() => preview = next);
                                    },
                                  ),
                                  if (plan.requiresRestart)
                                    const ListTile(
                                      leading: Icon(Icons.restart_alt),
                                      title: Text('应用后建议重启应用'),
                                      subtitle: Text('播放与界面设置需要重新初始化'),
                                    ),
                                  ...plan.notes.map(
                                    (note) => ListTile(
                                      leading: const Icon(Icons.info_outline),
                                      title: Text(note),
                                    ),
                                  ),
                                  if (plan.skips.isNotEmpty) ...[
                                    const Divider(),
                                    const ListTile(title: Text('跳过项')),
                                    ...plan.skips
                                        .take(30)
                                        .map(
                                          (skip) => ListTile(
                                            dense: true,
                                            title: Text(
                                              skip.key.isEmpty
                                                  ? skip.category
                                                  : skip.key,
                                            ),
                                            subtitle: Text(skip.reason),
                                          ),
                                        ),
                                  ],
                                ],
                              ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final next = await _service.preview(
                                  record.key,
                                  selection: BackupSelection(selected),
                                  mergeLists: mergeLists,
                                );
                                setSheetState(() => preview = next);
                              },
                              child: const Text('刷新预览'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: plan == null
                                  ? null
                                  : () async {
                                      final filtered = RestorePlan(
                                        manifest: plan.manifest,
                                        changes: plan.changes
                                            .where(
                                              (c) =>
                                                  selected.contains(c.category),
                                            )
                                            .toList(),
                                        skips: plan.skips
                                            .where(
                                              (s) =>
                                                  selected.contains(s.category),
                                            )
                                            .toList(),
                                        selectedCategories: selected.toList(),
                                        requiresRestart: plan.requiresRestart,
                                        notes: plan.notes,
                                        fontFamily: plan.fontFamily,
                                      );
                                      if (filtered.isEmpty) {
                                        SmartDialog.showToast('所选分类没有可应用的变更');
                                        return;
                                      }
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('确认恢复'),
                                          content: const Text(
                                            '恢复前会创建本地回滚快照。若中途失败，会尝试恢复旧设置；成功后部分设置可能需要重启。',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Get.back(result: false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Get.back(result: true),
                                              child: const Text('开始恢复'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok != true) return;
                                      try {
                                        await _service.applyRestore(
                                          RestorePreview(
                                            plan: filtered,
                                            font: selected.contains('font')
                                                ? preview?.font
                                                : null,
                                          ),
                                        );
                                        if (context.mounted)
                                          Navigator.pop(context);
                                        SmartDialog.showToast(
                                          filtered.requiresRestart
                                              ? '恢复完成，建议重启应用'
                                              : '恢复完成',
                                        );
                                      } on Object catch (e) {
                                        SmartDialog.showToast(
                                          '恢复失败：' + e.toString(),
                                        );
                                      }
                                    },
                              child: const Text('应用所选'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    } on Object catch (e) {
      SmartDialog.showToast('无法预览：' + e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _categorySummary(RestorePlan plan, String id) {
    final changes = plan.changes.where((c) => c.category == id).length;
    final skips = plan.skips.where((s) => s.category == id).length;
    if (changes == 0 && skips == 0) return '空内容，不会删除现有数据';
    return '变更 ' +
        changes.toString() +
        ' 项' +
        (skips > 0 ? '，跳过 ' + skips.toString() + ' 项' : '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('S3 兼容备份'),
        actions: [
          IconButton(
            tooltip: '保存配置',
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          ValueListenableBuilder<BackupTaskState>(
            valueListenable: _service.state,
            builder: (context, state, _) {
              if (state.status == BackupTaskStatus.idle) {
                return const SizedBox.shrink();
              }
              return ListTile(
                leading: state.isRunning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        state.status == BackupTaskStatus.failed
                            ? Icons.error_outline
                            : Icons.cloud_done_outlined,
                        color: state.status == BackupTaskStatus.failed
                            ? theme.colorScheme.error
                            : null,
                      ),
                title: Text(state.status.name),
                subtitle: Text(state.message),
              );
            },
          ),
          const _SectionTitle('连接'),
          _field(_name, '服务名称（仅本机显示）'),
          _field(_endpoint, 'Endpoint', hint: 'https://s3.example.com'),
          _field(_bucket, 'Bucket'),
          _field(_region, 'Region', hint: 'AWS 使用实际区域；R2 使用 auto'),
          _field(_prefix, 'Prefix', hint: 'PiliPlusBackups'),
          ListTile(
            title: const Text('寻址模式'),
            trailing: DropdownButton<S3AddressingMode>(
              value: _addressing,
              items: S3AddressingMode.values
                  .map(
                    (mode) => DropdownMenuItem(
                      value: mode,
                      child: Text(
                        mode == S3AddressingMode.pathStyle
                            ? 'path-style'
                            : 'virtual-hosted',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _addressing = value ?? _addressing),
            ),
          ),
          _field(_timeout, '超时（秒）'),
          _field(
            _accessKey,
            'Access Key ID',
            hint: _hasCredentials ? '已保存，留空不修改' : '首次配置必填',
          ),
          _field(
            _secretKey,
            'Secret Access Key',
            hint: _hasCredentials ? '已保存，留空不修改' : '首次配置必填',
            obscure: true,
          ),
          _field(_sessionToken, 'Session Token（可选）', obscure: true),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _testConnection,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('保存并测试连接'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshSnapshots,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新快照'),
                ),
              ],
            ),
          ),
          const Divider(),
          const _SectionTitle('备份内容'),
          ...BackupRegistry.categories.map(
            (category) => CheckboxListTile(
              value: _selection.includes(category.id),
              title: Text(category.label),
              subtitle: Text(
                category.description + (category.sensitive ? '（敏感，默认不选）' : ''),
              ),
              onChanged: (value) => setState(() {
                _selection = _selection.toggle(category.id, value == true);
              }),
            ),
          ),
          const Divider(),
          const _SectionTitle('加密'),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('恢复密钥'),
            subtitle: Text(
              _keyId == null ? '未生成。备份前会生成并显示恢复码。' : '已保存 · 标识 ' + _keyId!,
            ),
            trailing: TextButton(
              onPressed: _showRecoveryCode,
              child: Text(_keyId == null ? '生成' : '查看恢复码'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('新设备：输入恢复码'),
            subtitle: const Text('只导入密钥，不会上传任何数据'),
            onTap: _importRecoveryCode,
          ),
          const Divider(),
          const _SectionTitle('自动备份'),
          SwitchListTile(
            value: _autoEnabled,
            onChanged: (value) => setState(() => _autoEnabled = value),
            title: const Text('启用自动备份'),
            subtitle: const Text(
              '仅在 App 启动、回到前台、网络恢复及设置变更后尝试；不承诺 iOS 固定时间后台执行。',
            ),
          ),
          SwitchListTile(
            value: _wifiOnly,
            onChanged: (value) => setState(() => _wifiOnly = value),
            title: const Text('仅 Wi-Fi'),
          ),
          _field(_interval, '最小间隔（小时）'),
          _field(_retain, '保留自动快照数量'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _busy ? null : _backupNow,
              icon: const Icon(Icons.backup_outlined),
              label: const Text('立即备份'),
            ),
          ),
          const Divider(),
          const _SectionTitle('快照'),
          if (_loadingSnapshots)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_records.isEmpty)
            const ListTile(
              title: Text('还没有列出快照'),
              subtitle: Text('检查连接后点“刷新快照”；新设备可看到已有备份集'),
            )
          else
            ..._records.map(
              (record) => Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  title: Text(_formatTime(record.createdAt)),
                  subtitle: Text(
                    (record.auto ? '自动' : '手动') +
                        ' · ' +
                        _formatBytes(record.size) +
                        ' · 设备 ' +
                        record.deviceId.substring(
                          0,
                          record.deviceId.length > 6
                              ? 6
                              : record.deviceId.length,
                        ) +
                        (record.categories.isEmpty
                            ? ''
                            : ' · ' +
                                  record.categories.length.toString() +
                                  ' 类'),
                  ),
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      IconButton(
                        tooltip: '恢复',
                        icon: const Icon(Icons.restore),
                        onPressed: _busy ? null : () => _restore(record),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy ? null : () => _delete(record),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_records.isNotEmpty)
            TextButton.icon(
              onPressed: _busy ? null : _cleanup,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理旧自动快照'),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '凭据保存在系统安全存储；快照使用 AES-256-GCM 加密。S3 Secret Key 不会作为备份密钥。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return bytes.toString() + ' B';
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toStringAsFixed(1) + ' KiB';
    }
    return (bytes / 1024 / 1024).toStringAsFixed(1) + ' MiB';
  }

  static String _formatTime(String raw) {
    final parsed = DateTime.tryParse(raw)?.toLocal();
    if (parsed == null) return raw;
    String two(int v) => v.toString().padLeft(2, '0');
    return parsed.year.toString() +
        '-' +
        two(parsed.month) +
        '-' +
        two(parsed.day) +
        ' ' +
        two(parsed.hour) +
        ':' +
        two(parsed.minute);
  }

  static String _s3Message(S3Exception e) => switch (e.failure) {
    S3Failure.auth => 'S3 鉴权失败，请检查 Access Key',
    S3Failure.accessDenied => '没有执行该操作的权限',
    S3Failure.notFound => 'Bucket 或对象不存在',
    S3Failure.signature => '签名失败，请检查 Endpoint、Region 和寻址模式',
    S3Failure.region => 'Region 与 Endpoint 不匹配',
    S3Failure.clockSkew => '设备时间偏差过大，请校准后重试',
    S3Failure.preconditionFailed => '同名快照已存在，未覆盖',
    S3Failure.conflict => '同名对象内容不同，未覆盖',
    S3Failure.network => '网络不可用',
    S3Failure.tls => 'TLS 证书校验失败',
    S3Failure.timeout => '请求超时',
    S3Failure.server => 'S3 服务暂时不可用',
    S3Failure.rateLimited => 'S3 服务限流',
    S3Failure.invalidResponse => 'S3 响应无法识别',
    S3Failure.cancelled => '请求已取消',
  };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall,
    ),
  );
}
