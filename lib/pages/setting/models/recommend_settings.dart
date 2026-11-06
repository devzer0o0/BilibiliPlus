import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/pages/setting/ai_recommend.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/recommend_age_filter.dart';
import 'package:PiliPlus/utils/recommend_filter.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide StatefulBuilder;

List<SettingsModel> get recommendSettings => [
  NormalModel(
    title: 'AI 推荐筛选',
    subtitle: '关键词、观看行为与反馈共同排序；默认关闭',
    leading: const Icon(Icons.auto_awesome_outlined),
    getSubtitle: () {
      final settings = Pref.aiRecommendSettings;
      if (!settings.enabled) return '未启用';
      // ignore: prefer_interpolation_to_compose_strings
      return '已启用 · ' +
          settings.mode.label +
          (settings.hasModel ? ' · 已配置模型' : ' · 未配置模型');
    },
    onTap: (context, setState) async {
      await Get.to(() => const AiRecommendSettingsPage());
      setState();
    },
  ),
  const SwitchModel(
    title: '首页使用app端推荐',
    subtitle: '若web端推荐不太符合预期，可尝试切换至app端推荐',
    leading: Icon(Icons.model_training_outlined),
    setKey: SettingBoxKey.appRcmd,
    defaultVal: true,
    needReboot: true,
  ),
  SwitchModel(
    title: '保留首页推荐刷新',
    subtitle: '下拉刷新时保留上次内容',
    leading: const Icon(Icons.refresh),
    setKey: SettingBoxKey.enableSaveLastData,
    defaultVal: true,
    onChanged: (value) {
      try {
        Get.find<RcmdController>()
          ..enableSaveLastData = value
          ..lastRefreshAt = null;
      } catch (e) {
        if (kDebugMode) debugPrint('$e');
      }
    },
  ),
  SwitchModel(
    title: '显示上次看到位置提示',
    subtitle: '保留上次推荐时，在上次刷新位置显示提示',
    leading: const Icon(Icons.tips_and_updates_outlined),
    setKey: SettingBoxKey.savedRcmdTip,
    defaultVal: true,
    onChanged: (value) {
      try {
        Get.find<RcmdController>()
          ..savedRcmdTip = value
          ..lastRefreshAt = null;
      } catch (e) {
        if (kDebugMode) debugPrint('$e');
      }
    },
  ),
  getVideoFilterSelectModel(
    title: '点赞率',
    suffix: '%',
    key: SettingBoxKey.minLikeRatioForRecommend,
    values: [0, 1, 2, 3, 4],
    onChanged: (value) => RecommendFilter.minLikeRatioForRecommend = value,
    filterScope: 'Web推荐、热门、分区',
  ),
  getBanWordModel(
    title: '标题关键词过滤',
    key: SettingBoxKey.banWordForRecommend,
    onChanged: (value) {
      RecommendFilter.rcmdRegExp = value;
      RecommendFilter.enableFilter = value.pattern.isNotEmpty;
    },
    banScope: '推荐、热门、分区、相关视频',
  ),
  getBanWordModel(
    title: '分区关键词过滤',
    key: SettingBoxKey.banWordForZone,
    onChanged: (value) {
      VideoHttp.zoneRegExp = value;
      VideoHttp.enableFilter = value.pattern.isNotEmpty;
    },
    banScope: 'App推荐、热门、分区',
  ),
  getVideoFilterSelectModel(
    title: '视频时长',
    suffix: 's',
    key: SettingBoxKey.minDurationForRcmd,
    values: [0, 30, 60, 90, 120],
    onChanged: (value) => RecommendFilter.minDurationForRcmd = value,
    filterScope: '推荐、相关视频',
  ),
  getVideoFilterSelectModel(
    title: '播放量',
    key: SettingBoxKey.minPlayForRcmd,
    values: [0, 50, 100, 500, 1000],
    onChanged: (value) => RecommendFilter.minPlayForRcmd = value,
    filterScope: '推荐、热门、分区、相关视频',
  ),
  // Stored as a day count rather than an index, so adding a rung later does not
  // silently change what an existing setting means. The custom rung keeps its
  // cutoff date under a separate key.
  NormalModel(
    title: '发布时间过滤',
    subtitle: '只显示所选时间范围内发布的推荐视频；不限则与之前行为一致',
    leading: const Icon(Icons.calendar_month_outlined),
    getSubtitle: () {
      final current = RecommendFilter.ageFilter;
      if (current.isCustom) {
        final after = RecommendFilter.customAgeAfter;
        return after == null
            ? '当前: 自定义时间（未选择日期，暂不过滤）'
            : '当前: ${DateFormatUtils.longFormat.format(after)} 之后发布';
      }
      return current.isEnabled
          ? '当前: ${current.label}（过滤早于该时间的视频）'
          : '当前: 不限（不过滤发布时间）';
    },
    onTap: (context, setState) async {
      // SelectDialog rather than RadioListTile: the rest of this page uses it,
      // and RadioListTile's groupValue/onChanged are deprecated in this Flutter.
      final result = await showDialog<RecommendAgeFilter>(
        context: context,
        builder: (context) => SelectDialog<RecommendAgeFilter>(
          title: '发布时间过滤',
          value: RecommendFilter.ageFilter,
          values: [
            for (final filter in RecommendAgeFilter.values)
              (filter, _ageFilterLabel(filter)),
          ],
        ),
      );
      if (result == null) return;
      DateTime? customAfter;
      if (result.isCustom) {
        // The dialog awaits; the row may be gone by the time it closes.
        if (!context.mounted) return;
        final now = DateTime.now();
        final earliest = DateTime(2009, 6, 26);
        final existing = RecommendFilter.customAgeAfter;
        final initialDate =
            existing != null &&
                !existing.isAfter(now) &&
                !existing.isBefore(earliest)
            ? existing
            : now.subtract(const Duration(days: 30));
        final picked = await showDatePicker(
          context: context,
          initialDate: initialDate,
          firstDate: earliest,
          lastDate: now,
        );
        // Cancelling the picker keeps the previous setting: a filter that hides
        // content must not switch itself on from a dismissed dialog.
        if (picked == null) return;
        customAfter = DateTime(picked.year, picked.month, picked.day);
      }
      RecommendFilter.ageFilter = result;
      await GStorage.setting.put(
        SettingBoxKey.rcmdAgeFilterDays,
        result.storedValue,
      );
      if (customAfter != null) {
        // Remembered even when another rung is chosen later, so reopening the
        // picker starts from the last custom date instead of a guess.
        RecommendFilter.customAgeAfter = customAfter;
        await GStorage.setting.put(
          SettingBoxKey.rcmdAgeFilterCustomAfter,
          customAfter.millisecondsSinceEpoch,
        );
      }
      setState();
      // The feed is fetched, not observed: without this the new window only
      // takes effect on the next manual refresh, which reads as "the setting
      // did nothing".
      try {
        final controller = Get.find<RcmdController>()
          ..page = 0
          ..isEnd = false;
        await controller.onRefresh();
      } catch (e) {
        if (kDebugMode) debugPrint('$e');
      }
    },
  ),
  SwitchModel(
    title: '已关注UP豁免推荐过滤',
    subtitle: '推荐中已关注用户发布的内容不会被过滤',
    leading: const Icon(Icons.favorite_border_outlined),
    setKey: SettingBoxKey.exemptFilterForFollowed,
    defaultVal: true,
    onChanged: (value) => RecommendFilter.exemptFilterForFollowed = value,
  ),
  SwitchModel(
    title: '过滤器也应用于详情页相关视频',
    subtitle: '其它（如热门视频、搜索等）均不受过滤器影响，无法豁免相关视频中的已关注UP',
    leading: const Icon(Icons.explore_outlined),
    setKey: SettingBoxKey.applyFilterToRelatedVideos,
    defaultVal: true,
    onChanged: (value) => RecommendFilter.applyFilterToRelatedVideos = value,
  ),
];

/// Label for one age rung. The custom rung shows the picked date so the dialog
/// answers "what does 自定义时间 currently mean" without opening a picker.
String _ageFilterLabel(RecommendAgeFilter filter) {
  if (!filter.isCustom) return filter.label;
  final after = RecommendFilter.customAgeAfter;
  return after == null
      ? filter.label
      : '${filter.label}（${DateFormatUtils.longFormat.format(after)} 之后）';
}
