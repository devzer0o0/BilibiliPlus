// Seeds a logged-in account into the iOS Simulator app container.
//
// Runs inside the flutter_test VM because the account model pulls in
// Flutter bindings that a bare `dart run` cannot compile.
//
//   SEED_CONTAINER=<container> SEED_COOKIES=<json> \
//     flutter test test/tools/seed_account_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

void main() {
  test('seed account', () async {
    final container = Platform.environment['SEED_CONTAINER'];
    final cookiesFile = Platform.environment['SEED_COOKIES'];
    if (container == null || cookiesFile == null) {
      markTestSkipped('SEED_CONTAINER/SEED_COOKIES not set');
      return;
    }
    final cookies = (jsonDecode(File(cookiesFile).readAsStringSync()) as Map)
        .cast<String, String>();

    final hivePath = p.join(
      container,
      'Library',
      'Application Support',
      'hive',
    );
    Hive.init(hivePath);
    GStorage.regAdapter();

    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('localCache');
    final accountBox = await Hive.openBox<LoginAccount>('account');

    // BiliCookieJar.fromJson builds the domain/path map the adapters expect.
    final jar = BiliCookieJar.fromJson(cookies);

    // The type set decides which slot Accounts.refresh() binds the account to;
    // without AccountType.main the app still shows "点击登录".
    final account = LoginAccount(
      jar,
      null,
      null,
      <AccountType>{...AccountType.values},
    );
    await accountBox.put(account.mid.toString(), account);

    // The profile header reads Pref.userInfoCache, which login_utils writes
    // from the nav response.
    final navFile = Platform.environment['SEED_NAV'];
    if (navFile != null && File(navFile).existsSync()) {
      final userInfoBox = await Hive.openBox<UserInfoData>('userInfo');
      final nav =
          (jsonDecode(File(navFile).readAsStringSync()) as Map)
              .cast<String, dynamic>();
      await userInfoBox.put('userInfoCache', UserInfoData.fromJson(nav));
    }

    // ignore: avoid_print
    print('seeded mid=' + account.mid.toString());
    await Hive.close();
  });
}