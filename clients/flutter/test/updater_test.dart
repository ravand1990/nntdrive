import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/updater.dart';

void main() {
  test('version comparison handles semver ordering', () {
    expect(isNewerVersion('0.2.2', '0.2.1'), isTrue);
    expect(isNewerVersion('0.3.0', '0.2.9'), isTrue);
    expect(isNewerVersion('1.0.0', '0.99.99'), isTrue);
    expect(isNewerVersion('0.9.0', '0.10.0'), isFalse);
    expect(isNewerVersion('v0.2.1', '0.2.1'), isFalse);
    expect(isNewerVersion('0.2.1', '0.2.1'), isFalse);
  });

  test('checksums are parsed for the requested asset', () {
    final hash = 'b' * 64;
    final body = 'aaa  nntdrive-linux-x64.tar.gz\n$hash *nntdrive-windows-x64.zip\n';
    expect(parseChecksum(body, 'nntdrive-windows-x64.zip'), hash);
    expect(parseChecksum(body, 'missing.zip'), isNull);
  });

  test('asset name matches the host platform', () {
    final name = platformAssetName();
    if (Platform.isWindows) {
      expect(name, 'nntdrive-windows-x64.zip');
    } else if (Platform.isLinux) {
      expect(name, 'nntdrive-linux-x64.tar.gz');
    }
  });
}
