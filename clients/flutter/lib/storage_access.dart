import 'dart:io';

import 'package:flutter/services.dart';

/// All access decisions stay on-device. A SAF URI is not a POSIX sync root.
class StorageAccessException implements Exception {
  const StorageAccessException(this.permissionRequired);
  final bool permissionRequired;
  @override
  String toString() => permissionRequired
      ? 'Storage access is required. Grant access, then retry this folder.'
      : 'Cannot read this folder. Check that it exists and is accessible, then retry.';
}

/// Why the platform refused storage access.
///
/// [denied] may be asked again after explaining why access is needed;
/// [permanentlyDenied] and [settingsRequired] cannot: only the system settings
/// screen can grant access, so the client must stop prompting.
enum StoragePermissionOutcome {
  granted,
  denied,
  permanentlyDenied,
  settingsRequired,
}

/// What the UI does next after a refusal.
enum StoragePermissionNext { proceed, retry, openSettings }

/// Only a refusal the OS still lets us ask about gets another prompt.
StoragePermissionNext permissionNextStep(StoragePermissionOutcome outcome) {
  switch (outcome) {
    case StoragePermissionOutcome.granted:
      return StoragePermissionNext.proceed;
    case StoragePermissionOutcome.denied:
      return StoragePermissionNext.retry;
    case StoragePermissionOutcome.permanentlyDenied:
    case StoragePermissionOutcome.settingsRequired:
      return StoragePermissionNext.openSettings;
  }
}

bool permissionNeedsSettings(StoragePermissionOutcome outcome) =>
    permissionNextStep(outcome) == StoragePermissionNext.openSettings;

/// Parses the platform's answer. Older platforms returned a bare boolean; an
/// unknown shape is treated as a plain denial so nothing can prompt in a loop.
StoragePermissionOutcome parsePermissionOutcome(Object? value) {
  if (value is bool) {
    return value
        ? StoragePermissionOutcome.granted
        : StoragePermissionOutcome.denied;
  }
  if (value is Map) {
    if (value['granted'] == true) return StoragePermissionOutcome.granted;
    switch (value['outcome']) {
      case 'permanently_denied':
        return StoragePermissionOutcome.permanentlyDenied;
      case 'settings_required':
        return StoragePermissionOutcome.settingsRequired;
    }
  }
  return StoragePermissionOutcome.denied;
}

class StorageAccess {
  const StorageAccess();
  static const channel = MethodChannel('dev.nntdrive/storage_access');

  bool get isAndroid => Platform.isAndroid;

  Future<bool> permissionRequired(String path) async {
    if (!isAndroid) return false;
    return await channel.invokeMethod<bool>('status', {'path': path}) ?? true;
  }

  /// No timer/background check may call this: only an explicit user action.
  Future<StoragePermissionOutcome> request() async {
    if (!isAndroid) return StoragePermissionOutcome.denied;
    return parsePermissionOutcome(
        await channel.invokeMethod<Object?>('request'));
  }

  /// Opens this app's system settings page. Only for outcomes where another
  /// prompt cannot work.
  Future<void> openSettings() async {
    if (!isAndroid) return;
    // The platform's return value is not needed, so never cast it.
    await channel.invokeMethod<Object?>('openSettings');
  }

  Future<String?> privateFolder() async =>
      isAndroid ? await channel.invokeMethod<String>('privateFolder') : null;

  Future<void> check(String path) async {
    if (await permissionRequired(path)) {
      throw const StorageAccessException(true);
    }
    try {
      // exists() alone can succeed for a directory whose listing is denied.
      // Drain the immediate listing, without following links or reading content.
      await Directory(path).list(followLinks: false).drain<void>();
    } on FileSystemException {
      throw const StorageAccessException(false);
    }
  }
}
