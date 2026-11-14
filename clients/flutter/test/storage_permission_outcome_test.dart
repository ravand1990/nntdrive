import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/storage_access.dart';

void main() {
  test('platform answers map to a refusal the OS can or cannot re-ask', () {
    expect(parsePermissionOutcome(true), StoragePermissionOutcome.granted);
    expect(parsePermissionOutcome(false), StoragePermissionOutcome.denied);
    expect(
      parsePermissionOutcome({'granted': true, 'outcome': 'denied'}),
      StoragePermissionOutcome.granted,
    );
    expect(
      parsePermissionOutcome({'granted': false, 'outcome': 'denied'}),
      StoragePermissionOutcome.denied,
    );
    expect(
      parsePermissionOutcome(
          {'granted': false, 'outcome': 'permanently_denied'}),
      StoragePermissionOutcome.permanentlyDenied,
    );
    expect(
      parsePermissionOutcome({'granted': false, 'outcome': 'settings_required'}),
      StoragePermissionOutcome.settingsRequired,
    );
  });

  test('unknown or missing answers fail closed to a retryable denial', () {
    expect(parsePermissionOutcome(null), StoragePermissionOutcome.denied);
    expect(parsePermissionOutcome('granted'), StoragePermissionOutcome.denied);
    expect(parsePermissionOutcome({'outcome': 'something_new'}),
        StoragePermissionOutcome.denied);
    expect(parsePermissionOutcome({'granted': false}),
        StoragePermissionOutcome.denied);
  });

  test('only a retryable denial leads to another prompt', () {
    expect(permissionNextStep(StoragePermissionOutcome.granted),
        StoragePermissionNext.proceed);
    expect(permissionNextStep(StoragePermissionOutcome.denied),
        StoragePermissionNext.retry);
    expect(permissionNextStep(StoragePermissionOutcome.permanentlyDenied),
        StoragePermissionNext.openSettings);
    expect(permissionNextStep(StoragePermissionOutcome.settingsRequired),
        StoragePermissionNext.openSettings);
    expect(permissionNeedsSettings(StoragePermissionOutcome.denied), isFalse);
    expect(permissionNeedsSettings(StoragePermissionOutcome.granted), isFalse);
    expect(
        permissionNeedsSettings(StoragePermissionOutcome.permanentlyDenied),
        isTrue);
  });
}
