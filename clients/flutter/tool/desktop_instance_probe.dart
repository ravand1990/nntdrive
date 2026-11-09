import 'dart:io';

import 'package:nntdrive/desktop_instance.dart';

// Real-process ownership probe; no account, settings, journal or native library.
Future<void> main(List<String> args) async {
  try {
    final instance = await DesktopInstance.acquire(Directory(args.single));
    stdout.writeln('owned');
    await stdin.first;
    await instance.release();
  } on FileSystemException {
    stdout.writeln('busy');
    exitCode = 75;
  }
}
