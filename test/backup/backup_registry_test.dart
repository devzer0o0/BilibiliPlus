import 'package:PiliPlus/utils/backup/backup_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default selection is the portable baseline', () {
    final selection = BackupRegistry.defaultSelection;
    expect(selection.includes('general'), isTrue);
    expect(selection.includes('recommendFilter'), isTrue);
    expect(selection.includes('aiExplicit'), isTrue);
    expect(selection.includes('aiProfile'), isFalse);
    expect(selection.includes('font'), isFalse);
    expect(selection.includes('watchProgress'), isFalse);
  });

  test('credential keys are excluded even if a category lists them', () {
    for (final key in [
      'webdavPassword',
      'aiApiKey',
      's3SecretAccessKey',
      'accessToken',
      'badCertificateCallback',
    ]) {
      expect(BackupRegistry.isExcludedSettingKey(key), isTrue, reason: key);
    }
    expect(BackupRegistry.isExcludedSettingKey('banWordForRecommend'), isFalse);
  });

  test('portable values reject custom objects and deep nesting', () {
    expect(BackupRegistry.isPortableValue('x'), isTrue);
    expect(BackupRegistry.isPortableValue([1, true, 'x']), isTrue);
    expect(BackupRegistry.isPortableValue(Object()), isFalse);
    var deep = <String, Object?>{};
    var cursor = deep;
    for (var i = 0; i < 10; i++) {
      final next = <String, Object?>{};
      cursor['x'] = next;
      cursor = next;
    }
    expect(BackupRegistry.isPortableValue(deep), isFalse);
  });
}
