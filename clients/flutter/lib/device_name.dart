import 'dart:io';

import 'package:flutter/services.dart';

import 'file_rename.dart';

/// Device labels use the same portable Unicode validation as encrypted files.
String? deviceNameValidationError(String name) {
  final invalid = renameValidationError(name);
  if (invalid != null) return invalid;
  if (name.runes.length > 64) return 'Use at most 64 characters.';
  if (name.runes.any(
    (r) =>
        (r >= 0x80 && r <= 0x9f) ||
        (r >= 0x200b && r <= 0x200f) ||
        (r >= 0x2028 && r <= 0x202e) ||
        (r >= 0x2060 && r <= 0x206f) ||
        r == 0xfeff ||
        (r >= 0xfdd0 && r <= 0xfdef) ||
        (r & 0xffff) >= 0xfffe,
  )) {
    return 'Use printable characters without invisible control characters.';
  }
  return null;
}

/// Pure seam: OS-provided strings are suggestions, never sent to auth or logs.
String deviceNameDefault({
  required String platform,
  String? displayName,
  String? model,
  String? computerName,
  String? hostname,
}) {
  bool meaningful(String? value) {
    if (value == null || deviceNameValidationError(value.trim()) != null) {
      return false;
    }
    final lower = value.trim().toLowerCase();
    return lower != 'localhost' &&
        !lower.startsWith('localhost.') &&
        lower != 'localhost.localdomain' &&
        lower != '(none)' &&
        !RegExp(r'^[a-f0-9]{12,64}$').hasMatch(lower);
  }

  final candidates = platform == 'android'
      ? [displayName, model]
      : platform == 'windows'
      ? [computerName, hostname]
      : [displayName, hostname];
  for (final candidate in candidates) {
    if (meaningful(candidate)) return candidate!.trim();
  }
  final label = switch (platform) {
    'android' => 'Android',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'macos' => 'Mac',
    'ios' => 'iOS',
    _ => platform,
  };
  return 'My $label device';
}

Future<String> readDeviceNameDefault() async {
  String? displayName;
  String? model;
  String? hostname;
  try {
    hostname = Platform.localHostname;
  } catch (_) {
    /* Use fallback. */
  }
  if (Platform.isAndroid) {
    try {
      final result = await const MethodChannel('dev.nntdrive/device_name')
          .invokeMapMethod<String, String>('read');
      displayName = result?['name'];
      model = result?['model'];
    } catch (_) {
      // Missing/denied platform APIs must not expose diagnostics or identifiers.
    }
  }
  return deviceNameDefault(
    platform: Platform.operatingSystem,
    displayName: displayName,
    model: model,
    computerName: Platform.environment['COMPUTERNAME'],
    hostname: hostname,
  );
}
