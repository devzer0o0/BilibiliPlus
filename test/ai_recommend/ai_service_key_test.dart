import 'package:PiliPlus/utils/ai_recommend/ai_recommendation_service.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saving without a key keeps the stored one', () async {
    final store = MemorySecretStore({SecretKeys.aiApiKey: 'sk-old'});
    await applyApiKeyTo(store);
    expect(await store.read(SecretKeys.aiApiKey), 'sk-old');
    await applyApiKeyTo(store, apiKey: '   ');
    expect(await store.read(SecretKeys.aiApiKey), 'sk-old');
  });

  test('a new key replaces the stored one', () async {
    final store = MemorySecretStore({SecretKeys.aiApiKey: 'sk-old'});
    await applyApiKeyTo(store, apiKey: ' sk-new ');
    expect(await store.read(SecretKeys.aiApiKey), 'sk-new');
  });

  test('a clear only happens through the explicit action', () async {
    final store = MemorySecretStore({SecretKeys.aiApiKey: 'sk-old'});
    await applyApiKeyTo(store, apiKey: '');
    expect(await store.read(SecretKeys.aiApiKey), 'sk-old');
    await store.delete(SecretKeys.aiApiKey);
    expect(await store.read(SecretKeys.aiApiKey), isNull);
  });
}
