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

class StorageAccess {
  const StorageAccess();
  static const channel = MethodChannel('dev.nntdrive/storage_access');

  bool get isAndroid => Platform.isAndroid;

  Future<bool> permissionRequired(String path) async {
    if (!isAndroid) return false;
    return await channel.invokeMethod<bool>('status', {'path': path}) ?? true;
  }

  /// No timer/background check may call this: only an explicit user action.
  Future<bool> request() async =>
      isAndroid && (await channel.invokeMethod<bool>('request') ?? false);

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
