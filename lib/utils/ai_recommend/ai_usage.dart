// ignore_for_file: prefer_interpolation_to_compose_strings
import 'package:hive_ce/hive.dart';

class AiUsageSnapshot {
  const AiUsageSnapshot({
    this.requests = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  final int requests;
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;

  Map<String, dynamic> toJson() => {
    'requests': requests,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
  };

  static AiUsageSnapshot fromJson(Object? raw) {
    if (raw is! Map) return const AiUsageSnapshot();
    int value(Object? v) => v is int && v >= 0 ? v : 0;
    return AiUsageSnapshot(
      requests: value(raw['requests']),
      promptTokens: value(raw['promptTokens']),
      completionTokens: value(raw['completionTokens']),
    );
  }
}

abstract interface class AiUsageStore {
  Future<AiUsageSnapshot> read(String accountScope, DateTime day);
  Future<void> add(
    String accountScope,
    DateTime day, {
    int requests = 0,
    int promptTokens = 0,
    int completionTokens = 0,
  });
  Future<void> clear(String accountScope);
}

class HiveAiUsageStore implements AiUsageStore {
  HiveAiUsageStore(this.box);

  final Box<dynamic> box;

  static String key(String scope, DateTime day) =>
      'usage:' + scope + ':' + _day(day);

  static String _day(DateTime day) =>
      day.year.toString().padLeft(4, '0') +
      '-' +
      day.month.toString().padLeft(2, '0') +
      '-' +
      day.day.toString().padLeft(2, '0');

  @override
  Future<AiUsageSnapshot> read(String accountScope, DateTime day) async =>
      AiUsageSnapshot.fromJson(box.get(key(accountScope, day)));

  @override
  Future<void> add(
    String accountScope,
    DateTime day, {
    int requests = 0,
    int promptTokens = 0,
    int completionTokens = 0,
  }) async {
    final old = await read(accountScope, day);
    await box.put(key(accountScope, day), {
      'requests': old.requests + requests,
      'promptTokens': old.promptTokens + promptTokens,
      'completionTokens': old.completionTokens + completionTokens,
    });
  }

  @override
  Future<void> clear(String accountScope) async {
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith('usage:' + accountScope + ':'))
        .toList();
    for (final key in keys) {
      await box.delete(key);
    }
  }
}

class MemoryAiUsageStore implements AiUsageStore {
  final Map<String, AiUsageSnapshot> _items = {};

  @override
  Future<AiUsageSnapshot> read(String accountScope, DateTime day) async =>
      _items[HiveAiUsageStore.key(accountScope, day)] ??
      const AiUsageSnapshot();

  @override
  Future<void> add(
    String accountScope,
    DateTime day, {
    int requests = 0,
    int promptTokens = 0,
    int completionTokens = 0,
  }) async {
    final key = HiveAiUsageStore.key(accountScope, day);
    final old = await read(accountScope, day);
    _items[key] = AiUsageSnapshot(
      requests: old.requests + requests,
      promptTokens: old.promptTokens + promptTokens,
      completionTokens: old.completionTokens + completionTokens,
    );
  }

  @override
  Future<void> clear(String accountScope) async {
    _items.removeWhere((k, v) => k.startsWith('usage:' + accountScope));
  }
}
