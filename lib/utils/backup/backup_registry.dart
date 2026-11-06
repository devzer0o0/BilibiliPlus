import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/utils/storage_key.dart';

enum BackupSource {
  setting,
  videoSetting,
  blacklist,
  aiExplicit,
  aiProfile,
  searchHistory,
  localReplies,
  watchProgress,
  font,
}

enum RestoreStrategy {
  overwrite,
  mergeOrReplace,
  replaceProfile,
  installFont,
}

class BackupCategorySpec {
  const BackupCategorySpec({
    required this.id,
    required this.label,
    required this.description,
    required this.source,
    this.defaultSelected = true,
    this.sensitive = false,
    this.crossPlatformSkip = false,
    this.settingKeys = const [],
    this.strategy = RestoreStrategy.overwrite,
  });

  final String id;
  final String label;
  final String description;
  final BackupSource source;
  final bool defaultSelected;
  final bool sensitive;
  final bool crossPlatformSkip;
  final List<String> settingKeys;
  final RestoreStrategy strategy;
}

/// The only definition of what may leave the device in a cloud backup.
///
/// Unknown settings are excluded by default. Credentials are excluded by
/// source (they never live in the exported boxes) and by an extra key check.
abstract final class BackupRegistry {
  static const int schemaVersion = 1;

  static const List<BackupCategorySpec> categories = [
    BackupCategorySpec(
      id: 'general',
      label: '通用设置',
      description: '首页来源、动态、搜索、界面导航等通用偏好',
      source: BackupSource.setting,
      settingKeys: [
        SettingBoxKey.appRcmd,
        SettingBoxKey.enableSaveLastData,
        SettingBoxKey.savedRcmdTip,
        SettingBoxKey.autoUpdate,
        SettingBoxKey.recordSearchHistory,
        SettingBoxKey.searchSuggestion,
        SettingBoxKey.enableSearchRcmd,
        SettingBoxKey.enableSearchWord,
        SettingBoxKey.openInBrowser,
        SettingBoxKey.enableQuickFav,
        SettingBoxKey.showHotRcmd,
        SettingBoxKey.checkDynamic,
        SettingBoxKey.dynamicPeriod,
        SettingBoxKey.defaultDynamicType,
        SettingBoxKey.showDynInteraction,
        SettingBoxKey.showDecorate,
        SettingBoxKey.showMedal,
        SettingBoxKey.disableLikeMsg,
        SettingBoxKey.coinWithLike,
        SettingBoxKey.enableLivePhoto,
        SettingBoxKey.antiGoodsDyn,
        SettingBoxKey.antiGoodsReply,
        SettingBoxKey.saveReply,
        SettingBoxKey.enableLog,
        SettingBoxKey.defaultHomePage,
        SettingBoxKey.useSideBar,
        SettingBoxKey.hideSideBarLabel,
        SettingBoxKey.hideTopBar,
        SettingBoxKey.hideBottomBar,
        SettingBoxKey.barHideType,
        SettingBoxKey.liquidGlassNavBar,
        SettingBoxKey.tabBarSort,
        SettingBoxKey.navBarSort,
        SettingBoxKey.mainTabBarView,
      ],
    ),
    BackupCategorySpec(
      id: 'appearance',
      label: '界面与主题',
      description: '主题、颜色、字号、卡片宽度；设备相关项跨平台恢复时跳过',
      source: BackupSource.setting,
      crossPlatformSkip: true,
      settingKeys: [
        SettingBoxKey.themeMode,
        SettingBoxKey.dynamicColor,
        SettingBoxKey.customColor,
        SettingBoxKey.schemeVariant,
        SettingBoxKey.isPureBlackTheme,
        SettingBoxKey.reduceLuxColor,
        SettingBoxKey.displayMode,
        SettingBoxKey.smallCardWidth,
        SettingBoxKey.recommendCardWidth,
        SettingBoxKey.dynamicsWaterfallFlow,
        SettingBoxKey.dynamicsShowAllFollowedUp,
        SettingBoxKey.upPanelPosition,
        SettingBoxKey.msgBadgeMode,
        SettingBoxKey.dynamicBadgeMode,
        SettingBoxKey.msgUnReadTypeV2,
        SettingBoxKey.horizontalScreen,
        SettingBoxKey.optTabletNav,
        SettingBoxKey.appFontWeightV2,
        SettingBoxKey.subtitleFontScale,
        SettingBoxKey.subtitleFontScaleFS,
        SettingBoxKey.subtitleFontWeight,
        SettingBoxKey.springDescription,
      ],
    ),
    BackupCategorySpec(
      id: 'playback',
      label: '播放与弹幕偏好',
      description: '画质、音质、解码、缓冲、手势与弹幕显示；画质仍受目标设备能力门控',
      source: BackupSource.setting,
      crossPlatformSkip: true,
      settingKeys: [
        SettingBoxKey.defaultVideoQa,
        SettingBoxKey.defaultVideoQaCellular,
        SettingBoxKey.defaultAudioQa,
        SettingBoxKey.defaultAudioQaCellular,
        SettingBoxKey.defaultPicQa,
        SettingBoxKey.preferCodecs,
        SettingBoxKey.preferCodecsCellular,
        SettingBoxKey.hardwareDecoding,
        SettingBoxKey.bufferSize,
        SettingBoxKey.bufferSec,
        SettingBoxKey.liveBufferSize,
        SettingBoxKey.liveBufferSec,
        SettingBoxKey.videoSync,
        SettingBoxKey.autosync,
        SettingBoxKey.audioOutput,
        SettingBoxKey.audioPlayMode,
        SettingBoxKey.playerVolume,
        SettingBoxKey.maxVolume,
        SettingBoxKey.enableBackgroundPlay,
        SettingBoxKey.continuePlayInBackground,
        SettingBoxKey.pauseOnMinimize,
        SettingBoxKey.showSeekPreview,
        SettingBoxKey.enableAutoEnter,
        SettingBoxKey.enableAutoExit,
        SettingBoxKey.autoPiP,
        SettingBoxKey.enableQuickDouble,
        SettingBoxKey.enableAutoLongPressSpeed,
        SettingBoxKey.sliderDuration,
        SettingBoxKey.useRelativeSlide,
        SettingBoxKey.fullScreenGestureReverse,
        SettingBoxKey.horizontalPreview,
        SettingBoxKey.enableDragSubtitle,
        SettingBoxKey.btmProgressBehavior,
        SettingBoxKey.enableTapDm,
        SettingBoxKey.enableShowDanmaku,
        SettingBoxKey.enableShowLiveDanmaku,
        SettingBoxKey.mergeDanmaku,
        SettingBoxKey.danmakuWeight,
        SettingBoxKey.danmakuShowArea,
        SettingBoxKey.danmakuOpacity,
        SettingBoxKey.danmakuFontScale,
        SettingBoxKey.danmakuFontScaleFS,
        SettingBoxKey.danmakuDuration,
        SettingBoxKey.danmakuStaticDuration,
        SettingBoxKey.danmakuMassiveMode,
        SettingBoxKey.danmakuFixedV,
        SettingBoxKey.danmakuStatic2Scroll,
        SettingBoxKey.danmakuLineHeight,
        SettingBoxKey.danmakuStrokeWidth,
        SettingBoxKey.danmakuFontWeight,
        SettingBoxKey.pipNoDanmaku,
        SettingBoxKey.showVipDanmaku,
      ],
    ),
    BackupCategorySpec(
      id: 'recommendFilter',
      label: '推荐过滤规则',
      description: '标题关键词、时长、播放量、发布时间、关注豁免等明确规则',
      source: BackupSource.setting,
      settingKeys: [
        SettingBoxKey.minDurationForRcmd,
        SettingBoxKey.minPlayForRcmd,
        SettingBoxKey.minLikeRatioForRecommend,
        SettingBoxKey.exemptFilterForFollowed,
        SettingBoxKey.banWordForRecommend,
        SettingBoxKey.banWordForZone,
        SettingBoxKey.applyFilterToRelatedVideos,
      ],
    ),
    BackupCategorySpec(
      id: 'blacklist',
      label: '本地黑名单',
      description: '本地屏蔽的 UP 主；恢复时可选择合并去重或替换',
      source: BackupSource.blacklist,
      strategy: RestoreStrategy.mergeOrReplace,
    ),
    BackupCategorySpec(
      id: 'aiExplicit',
      label: 'AI 明确偏好',
      description: '想看/少看、兴趣描述、模式与预算；不含 API Key，恢复后不会自动启用外部请求',
      source: BackupSource.aiExplicit,
    ),
    BackupCategorySpec(
      id: 'aiProfile',
      label: 'AI 推测兴趣与反馈',
      description: '仅恢复到同一账号作用域；跨账号会跳过，避免画像混用',
      source: BackupSource.aiProfile,
      defaultSelected: false,
      sensitive: true,
      strategy: RestoreStrategy.replaceProfile,
    ),
    BackupCategorySpec(
      id: 'searchHistory',
      label: '搜索历史',
      description: '本地搜索词；默认不选',
      source: BackupSource.searchHistory,
      defaultSelected: false,
      sensitive: true,
      strategy: RestoreStrategy.mergeOrReplace,
    ),
    BackupCategorySpec(
      id: 'localReplies',
      label: '本地历史评论',
      description: '本机缓存的评论内容；默认不选',
      source: BackupSource.localReplies,
      defaultSelected: false,
      sensitive: true,
    ),
    BackupCategorySpec(
      id: 'watchProgress',
      label: '本地播放进度',
      description: '按 cid 的本地进度；默认不选，不包含完整观看轨迹',
      source: BackupSource.watchProgress,
      defaultSelected: false,
      sensitive: true,
    ),
    BackupCategorySpec(
      id: 'font',
      label: '自定义字体文件',
      description: '字体安装到目标设备的新路径，并单独提示',
      source: BackupSource.font,
      defaultSelected: false,
      sensitive: true,
      crossPlatformSkip: false,
      strategy: RestoreStrategy.installFont,
    ),
  ];

  static BackupCategorySpec? byId(String id) {
    for (final category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  static BackupSelection get defaultSelection => BackupSelection({
    for (final category in categories)
      if (category.defaultSelected) category.id,
  });

  /// Extra guard: even if a key is added to a category by mistake, these are
  /// never exported.
  static bool isExcludedSettingKey(String key) {
    final lower = key.toLowerCase();
    return lower.contains('password') ||
        lower.contains('secret') ||
        lower.contains('apikey') ||
        lower.contains('api_key') ||
        lower.contains('accesskey') ||
        lower.contains('sessiontoken') ||
        lower.contains('token') ||
        lower.contains('webdav') ||
        lower == 'badcertificatecallback' ||
        lower == 'downloadpath';
  }

  /// JSON-safe, bounded values only. Custom Hive objects are skipped, not
  /// stringified with toString().
  static bool isPortableValue(Object? value, {int depth = 0}) {
    if (depth > 8) return false;
    if (value == null || value is bool || value is num || value is String) {
      return true;
    }
    if (value is List) {
      if (value.length > 2000) return false;
      return value.every((e) => isPortableValue(e, depth: depth + 1));
    }
    if (value is Map) {
      if (value.length > 2000) return false;
      return value.entries.every(
        (e) => e.key is String && isPortableValue(e.value, depth: depth + 1),
      );
    }
    return false;
  }

  static bool isSupportedValueType(BackupCategorySpec spec, Object? value) {
    if (spec.source == BackupSource.blacklist) {
      return value is List && value.every((e) => e is int);
    }
    if (spec.source == BackupSource.searchHistory ||
        spec.source == BackupSource.localReplies) {
      return value is List && value.every((e) => e is String);
    }
    if (spec.source == BackupSource.watchProgress) {
      return value is Map &&
          value.entries.every((e) => e.key is String && e.value is int);
    }
    return isPortableValue(value);
  }
}
