import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// What the app can show for a file without handing it to another program.
enum PreviewKind { image, text, unsupported }

/// Largest image the app decodes in memory for a preview.
const int previewImageByteLimit = 32 * 1024 * 1024;

/// Largest text file the app reads for a preview.
const int previewTextByteLimit = 512 * 1024;

/// Most characters the app renders for one text preview.
const int previewTextCharLimit = 200 * 1000;

/// Shown whenever a file type has no in-app renderer yet.
const String unsupportedPreviewMessage =
    'This file type cannot be previewed in the app yet.';

const Set<String> _imageExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
};

const Set<String> _textExtensions = <String>{
  '.txt',
  '.md',
  '.markdown',
  '.log',
  '.csv',
  '.json',
  '.yaml',
  '.yml',
};

/// The preview the app can render for [fileName], decided from the name only.
///
/// Extension matching is lower-cased and never looks at content, so a renamed
/// file falls back to the download path instead of being guessed at.
PreviewKind previewKindFor(String fileName) {
  final lower = fileName.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return PreviewKind.unsupported;
  final extension = lower.substring(dot);
  if (_imageExtensions.contains(extension)) return PreviewKind.image;
  if (_textExtensions.contains(extension)) return PreviewKind.text;
  return PreviewKind.unsupported;
}

/// One preview, ready for the page to render, or the reason there is none.
class PreviewContent {
  const PreviewContent._({
    required this.kind,
    this.imageBytes,
    this.text,
    this.truncated = false,
    this.message,
    this.fromOfflineCopy = false,
    this.byteLength = 0,
  });

  /// An image decoded from [bytes]; the page renders it from memory only.
  factory PreviewContent.image(
    Uint8List bytes, {
    bool fromOfflineCopy = false,
  }) => PreviewContent._(
    kind: PreviewKind.image,
    imageBytes: bytes,
    fromOfflineCopy: fromOfflineCopy,
    byteLength: bytes.length,
  );

  /// Decrypted text, already bounded and safe to render.
  factory PreviewContent.text(
    String text, {
    bool truncated = false,
    bool fromOfflineCopy = false,
    int byteLength = 0,
  }) => PreviewContent._(
    kind: PreviewKind.text,
    text: text,
    truncated: truncated,
    fromOfflineCopy: fromOfflineCopy,
    byteLength: byteLength,
  );

  /// No preview, only [message] explaining why and the download fallback.
  factory PreviewContent.unavailable(String message) =>
      PreviewContent._(kind: PreviewKind.unsupported, message: message);

  final PreviewKind kind;
  final Uint8List? imageBytes;
  final String? text;
  final bool truncated;
  final String? message;
  final bool fromOfflineCopy;
  final int byteLength;

  bool get hasPreview => message == null && kind != PreviewKind.unsupported;
}

/// Looks up an already decrypted device copy of one revision, or null.
typedef PreviewOfflineLookup = File? Function(String fileId, String revisionId);

/// Downloads one revision into an exact destination path.
typedef PreviewDownload = Future<void> Function(String destination);

/// Raised when the bytes could not be read within the preview bounds.
class PreviewLoadException implements Exception {
  PreviewLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads one file into a bounded preview, decrypting only on this device.
///
/// The loader prefers an existing device copy and otherwise downloads into a
/// scratch file under [tempRoot], reads it and deletes it before returning, so
/// a preview never leaves decrypted bytes behind on disk. Leftovers from an
/// interrupted run are removed on first use.
class PreviewLoader {
  PreviewLoader({
    required this.tempRoot,
    required this.download,
    this.lookupOfflineCopy,
  });

  final Directory tempRoot;
  final PreviewDownload download;
  final PreviewOfflineLookup? lookupOfflineCopy;

  final Random _random = Random();
  bool _purged = false;

  Future<PreviewContent> load({
    required String fileId,
    required String revisionId,
    required String name,
    required int sizeBytes,
  }) async {
    final kind = previewKindFor(name);
    if (kind == PreviewKind.unsupported) {
      return PreviewContent.unavailable(unsupportedPreviewMessage);
    }
    final limit = kind == PreviewKind.image
        ? previewImageByteLimit
        : previewTextByteLimit;
    if (sizeBytes > limit) {
      return PreviewContent.unavailable(_tooLargeMessage(sizeBytes, limit));
    }

    Uint8List bytes;
    var fromOfflineCopy = false;
    final offline = lookupOfflineCopy?.call(fileId, revisionId);
    if (offline != null) {
      bytes = await offline.readAsBytes();
      fromOfflineCopy = true;
    } else {
      bytes = await _downloadToScratch(limit);
    }
    if (bytes.length > limit) {
      throw PreviewLoadException(_tooLargeMessage(bytes.length, limit));
    }
    return _describe(kind, bytes, fromOfflineCopy: fromOfflineCopy);
  }

  PreviewContent _describe(
    PreviewKind kind,
    Uint8List bytes, {
    required bool fromOfflineCopy,
  }) {
    if (kind == PreviewKind.image) {
      if (bytes.isEmpty) {
        throw PreviewLoadException(
          'The file is empty, so there is nothing to show.',
        );
      }
      return PreviewContent.image(bytes, fromOfflineCopy: fromOfflineCopy);
    }
    var text = utf8.decode(bytes, allowMalformed: true);
    var truncated = false;
    if (text.length > previewTextCharLimit) {
      text = text.substring(0, previewTextCharLimit);
      truncated = true;
    }
    return PreviewContent.text(
      text,
      truncated: truncated,
      fromOfflineCopy: fromOfflineCopy,
      byteLength: bytes.length,
    );
  }

  Future<Uint8List> _downloadToScratch(int limit) async {
    await _purgeOnce();
    await tempRoot.create(recursive: true);
    final scratch = File(
      p.join(
        tempRoot.path,
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}.part',
      ),
    );
    try {
      await download(scratch.path);
      final length = await scratch.length();
      if (length > limit) {
        throw PreviewLoadException(_tooLargeMessage(length, limit));
      }
      return await scratch.readAsBytes();
    } finally {
      // The decrypted scratch copy never outlives the read, including when the
      // download fails half-way through.
      try {
        if (await scratch.exists()) await scratch.delete();
      } catch (_) {
        // A file that cannot be deleted is retried by the next purge.
      }
    }
  }

  Future<void> _purgeOnce() async {
    if (_purged) return;
    _purged = true;
    await purgeStalePreviews(tempRoot);
  }

  /// Removes scratch files a crashed or interrupted preview left behind.
  ///
  /// Files touched within [olderThan] are kept so a preview that is still
  /// running is never pulled out from under itself.
  static Future<int> purgeStalePreviews(
    Directory root, {
    Duration olderThan = const Duration(minutes: 2),
    DateTime Function()? now,
  }) async {
    if (!await root.exists()) return 0;
    final cutoff = (now ?? DateTime.now)().subtract(olderThan);
    var removed = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final modified = await entity.lastModified();
        if (modified.isAfter(cutoff)) continue;
        await entity.delete();
        removed++;
      } catch (_) {
        // A scratch file that cannot be removed is harmless until the next run.
      }
    }
    return removed;
  }

  static String _tooLargeMessage(int sizeBytes, int limitBytes) =>
      'This file is too large to preview in the app '
      '(${_megabytes(sizeBytes)}; the limit is ${_megabytes(limitBytes)}).';

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
