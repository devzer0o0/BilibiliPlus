// ignore_for_file: prefer_interpolation_to_compose_strings
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:hive_ce/hive.dart';

abstract interface class InterestProfileStore {
  Future<InterestProfile?> read(String accountScope);
  Future<void> write(InterestProfile profile);
  Future<void> delete(String accountScope);
  Future<void> clearAll();
}

class HiveInterestProfileStore implements InterestProfileStore {
  HiveInterestProfileStore(this.box);
  final Box<dynamic> box;
  static String keyFor(String accountScope) => 'profile:' + accountScope;

  @override
  Future<InterestProfile?> read(String accountScope) async {
    final raw = box.get(keyFor(accountScope));
    if (raw is! Map) return null;
    return InterestProfile.fromJson(raw, accountScope: accountScope);
  }

  @override
  Future<void> write(InterestProfile profile) async {
    await box.put(keyFor(profile.accountScope), profile.toJson());
  }

  @override
  Future<void> delete(String accountScope) async {
    await box.delete(keyFor(accountScope));
  }

  @override
  Future<void> clearAll() async {
    await box.clear();
  }
}

class MemoryInterestProfileStore implements InterestProfileStore {
  final Map<String, InterestProfile> _items = {};

  @override
  Future<InterestProfile?> read(String accountScope) async =>
      _items[accountScope];

  @override
  Future<void> write(InterestProfile profile) async {
    _items[profile.accountScope] = profile;
  }

  @override
  Future<void> delete(String accountScope) async {
    _items.remove(accountScope);
  }

  @override
  Future<void> clearAll() async {
    _items.clear();
  }
}

abstract final class AccountScope {
  static const String anonymous = 'anon';

  static String forAccount({required bool isLogin, int? mid}) {
    if (isLogin && mid != null && mid > 0) return 'uid:' + mid.toString();
    return anonymous;
  }
}
