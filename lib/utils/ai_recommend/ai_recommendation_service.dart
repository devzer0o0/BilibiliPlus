// ignore_for_file: prefer_interpolation_to_compose_strings, prefer_initializing_formals
import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_provider.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_score_cache.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_usage.dart';
import 'package:PiliPlus/utils/ai_recommend/history_importer.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

class AiProbeResult {
  const AiProbeResult(this.ok, this.message);

  final bool ok;
  final String message;
}

/// Production wiring for AI recommendation filtering.
///
/// Everything here is fail-soft for the feed: if storage or the secret store is
/// unavailable, [settings] falls back to defaults and the pipeline reports
/// "local rules" instead of taking the feed down.
class AiRecommendationService {
  AiRecommendationService._();

  static final AiRecommendationService instance = AiRecommendationService._();

  final SecretStore secrets = FlutterSecretStore();
  AiRecommendationPipeline? _pipeline;

  AiRecommendSettings get settings {
    try {
      return Pref.aiRecommendSettings;
    } catch (_) {
      return AiRecommendSettings.defaults;
    }
  }

  AiRecommendationPipeline get pipeline =>
      _pipeline ??= AiRecommendationPipeline(
        settingsLoader: () async => settings,
        profileStore: HiveInterestProfileStore(GStorage.aiProfile),
        cache: HiveAiScoreCache(GStorage.aiScores),
        usage: HiveAiUsageStore(GStorage.aiScores),
        secrets: secrets,
        providerFactory: (config) => OpenAiCompatibleProvider(
          config: config,
          secrets: secrets,
        ),
      );

  String get recommendScope {
    try {
      final account = Accounts.get(.recommend);
      return AccountScope.forAccount(
        isLogin: account.isLogin,
        mid: account.mid,
      );
    } catch (_) {
      return AccountScope.anonymous;
    }
  }

  String get historyScope {
    try {
      final account = Accounts.history;
      return AccountScope.forAccount(
        isLogin: account.isLogin,
        mid: account.mid,
      );
    } catch (_) {
      return AccountScope.anonymous;
    }
  }

  bool get historyAccountMatchesRecommend => recommendScope == historyScope;

  Future<void> saveSettings(
    AiRecommendSettings next, {
    String? apiKey,
  }) async {
    final previous = settings;
    final baseChanged =
        _normalizeUrl(previous.baseUrl) != _normalizeUrl(next.baseUrl);
    await Pref.saveAiRecommendSettings(next);
    if (baseChanged || next.baseUrl.trim().isEmpty) {
      // A key is bound to the endpoint the user approved. Moving to another
      // endpoint (or a restored one) must not silently receive the old key.
      try {
        await secrets.delete(SecretKeys.aiApiKey);
      } catch (_) {
        // The old key is unusable anyway once the endpoint changed.
      }
    }
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      await secrets.write(SecretKeys.aiApiKey, apiKey.trim());
    }
  }

  static String _normalizeUrl(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();

  Future<bool> hasApiKey() async {
    try {
      final key = await secrets.read(SecretKeys.aiApiKey);
      return key != null && key.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearApiKey() => secrets.delete(SecretKeys.aiApiKey);

  Future<AiProbeResult> probe() async {
    final s = settings;
    if (!s.hasModel) {
      return const AiProbeResult(false, '请先填写服务地址和模型名称');
    }
    if (!await hasApiKey()) {
      return const AiProbeResult(false, '请先保存 API Key');
    }
    final provider = OpenAiCompatibleProvider(
      config: AiProviderConfig(
        baseUrl: s.baseUrl,
        model: s.model,
        timeoutMs: s.requestTimeoutMs,
        jsonMode: s.jsonMode,
        allowInsecureHttp: s.allowInsecureHttp,
      ),
      secrets: secrets,
    );
    final request = AiBatchRequest(
      candidates: const [
        AiCandidateEnvelope(
          requestId: 'c1',
          features: VideoFeatures(
            bvid: '',
            title: '测试候选：Flutter 与 NAS 教程',
            description: '这是一条用于验证结构化输出的合成候选',
          ),
        ),
      ],
      interests: [
        AiInterestRef(
          id: InterestProfile.topicId('NAS'),
          label: 'NAS',
          weight: 0.8,
        ),
      ],
      interestDescription: '测试连接，不包含真实观看记录',
    );
    try {
      final result = await provider.score(request);
      final count = result.scores.scoresByBvid.length;
      if (count == 0) {
        return const AiProbeResult(false, '模型返回了合法 JSON，但没有可用评分');
      }
      return AiProbeResult(
        true,
        '连接成功，收到 ' +
            count.toString() +
            ' 条评分，token ' +
            (result.promptTokens + result.completionTokens).toString(),
      );
    } on AiProviderException catch (e) {
      return AiProbeResult(false, _probeMessage(e));
    } on Object catch (_) {
      return const AiProbeResult(false, '模型服务验证失败');
    }
  }

  static String _probeMessage(AiProviderException e) => switch (e.kind) {
    AiProviderFailure.auth => '鉴权失败，请检查 API Key',
    AiProviderFailure.rateLimit => '服务限流，请稍后重试',
    AiProviderFailure.timeout => '连接超时',
    AiProviderFailure.network => '无法连接服务',
    AiProviderFailure.tls => 'TLS 证书校验失败',
    AiProviderFailure.server => '服务返回 5xx',
    AiProviderFailure.redirect => '服务返回重定向，已拒绝',
    AiProviderFailure.notConfigured => '配置不完整',
    AiProviderFailure.invalidResponse => '返回格式不符合约定的 JSON',
    AiProviderFailure.cancelled => '请求已取消',
    AiProviderFailure.requestTooLarge => '请求体过大',
  };

  Future<InterestProfile?> profile() => pipeline.profileFor(recommendScope);

  Future<void> deleteTopic(String topicId) =>
      pipeline.deleteTopic(recommendScope, topicId);

  Future<void> resetProfile() => pipeline.resetProfile(recommendScope);

  Future<void> clearScores() => pipeline.clearScores();

  Future<bool> recordFeedback({
    required VideoFeatures features,
    required FeedbackKind kind,
    List<String> modelTopics = const [],
  }) => pipeline.recordFeedback(
    features: features,
    kind: kind,
    accountScope: recommendScope,
    modelTopics: modelTopics,
  );

  Future<bool> undoLastFeedback() => pipeline.undoLastFeedback(recommendScope);

  Future<bool> recordWatch(WatchSignal signal) => pipeline.recordWatch(
    signal: signal,
    settings: settings,
  );

  /// Imports recent history after an explicit tap. Never called automatically,
  /// never sends history to a model.
  Future<HistoryImportResult> importRecentHistory() {
    final s = settings;
    if (!s.enabled || !s.useWatchHistory) {
      return Future.value(
        const HistoryImportResult.error('请先开启“使用观看记录学习兴趣”'),
      );
    }
    if (!historyAccountMatchesRecommend) {
      return Future.value(
        const HistoryImportResult.error(
          '观看历史账号与当前推荐账号不同，已拒绝导入以避免画像混用',
        ),
      );
    }
    return HistoryImporter().importRecent(
      store: HiveInterestProfileStore(GStorage.aiProfile),
      settings: s,
      accountScope: recommendScope,
    );
  }
}
