import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/pages/search/controller.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:PiliPlus/utils/backup/restore_coordinator.dart';
import 'package:PiliPlus/utils/font_utils.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';

/// Production writer for a restore. Every method is idempotent: replaying the
/// same plan after a crash must reach the same state.
class HiveRestoreWriter implements RestoreWriter {
  HiveRestoreWriter({required this.accountScope});

  final String accountScope;

  @override
  Future<void> setSetting(String key, Object? value) async {
    await GStorage.setting.put(key, value);
  }

  @override
  Future<void> replaceList(String category, List<Object?> values) async {
    switch (category) {
      case 'blacklist':
        final mids = values.whereType<int>().toSet();
        final current = GlobalData().blackMids
          ..clear()
          ..addAll(mids);
        Pref.blackMids = current;
      case 'searchHistory':
        final items = values.whereType<String>().toList();
        await GStorage.historyWord.put('cacheList', items);
        if (Get.isRegistered<BaseSearchController>()) {
          Get.find<BaseSearchController>().historyList.assignAll(items);
        }
      case 'localReplies':
        final box = GStorage.reply;
        if (box == null) {
          throw const RestoreFailure('评论缓存未启用，无法恢复本地评论');
        }
        final decoded = <int, Uint8List>{};
        var index = 0;
        for (final value in values.whereType<String>()) {
          try {
            decoded[index++] = base64Decode(value);
          } on FormatException {
            throw const RestoreFailure('本地评论数据不合法');
          }
        }
        await box.clear();
        await box.putAll(decoded);
    }
  }

  @override
  Future<void> replaceProfile(Map<String, dynamic> profile) async {
    final store = HiveInterestProfileStore(GStorage.aiProfile);
    if (profile.isEmpty) {
      await store.delete(accountScope);
      return;
    }
    await store.write(
      InterestProfile.fromJson(profile, accountScope: accountScope),
    );
  }

  @override
  Future<void> setAiSettings(Map<String, dynamic> settings) async {
    final parsed = AiRecommendSettings.fromMap(settings).copyWith(
      enabled: false,
    );
    await Pref.saveAiRecommendSettings(parsed);
  }

  @override
  Future<void> mergeProgress(Map<String, int> values) async {
    await GStorage.watchProgress.putAll(values);
  }

  @override
  Future<void> installFont(Uint8List bytes, String family) async {
    await FontUtils.fontFile.writeAsBytes(bytes, flush: true);
    final name = family.trim().isEmpty ? 'CustomFont' : family.trim();
    try {
      await ui.loadFontFromList(bytes, fontFamily: name);
    } catch (_) {
      // The file and setting are still written; a restart will retry loading.
    }
    await GStorage.setting.put(SettingBoxKey.appFont, name);
  }

  @override
  Object? readSetting(String key) => GStorage.setting.get(key);
}
