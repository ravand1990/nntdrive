import 'dart:io';

import 'package:path/path.dart' as p;

/// Retain the descriptor for the process lifetime. Never delete/replace this
/// inode: doing so permits two owners with different OS locks.
class DesktopInstance {
  DesktopInstance._(this._file);
  final RandomAccessFile _file;

  static Future<DesktopInstance> acquire(Directory support) async {
    await support.create(recursive: true);
    final file = await File(p.join(support.path, 'desktop-session.lock'))
        .open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
      return DesktopInstance._(file);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<void> release() => _file.close();
}
