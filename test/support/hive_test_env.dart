import 'dart:io';

import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:hive_ce/hive.dart';

/// Opens the Hive boxes the app reads during widget construction.
///
/// Accounts persist their buvid, which comes from the settings box, so any test
/// that writes an account needs the settings box open before the first write.
Future<void> openTestStorage() async {
  GStorage.setting = await Hive.openBox('setting');
  GStorage.video = await Hive.openBox('video');
  GStorage.localCache = await Hive.openBox('localCache');
  GStorage.userInfo = await Hive.openBox<UserInfoData>('userInfo');
  GStorage.historyWord = await Hive.openBox('historyWord');
  GStorage.watchProgress = await Hive.openBox<int>('watchProgress');
  Accounts.account = await Hive.openBox('account');
}

/// Creates a throwaway Hive home, opens the storage boxes and registers a
/// teardown that removes the directory again.
Future<Directory> setUpTestStorage() async {
  final dir = await Directory.systemTemp.createTemp('piliplus-test-');
  Hive.init(dir.path);
  GStorage.regAdapter();
  await openTestStorage();
  return dir;
}
