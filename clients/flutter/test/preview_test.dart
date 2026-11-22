import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/preview.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('preview-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<List<String>> scratchFiles() async {
    if (!await root.exists()) return const <String>[];
    final names = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      names.add(p.basename(entity.path));
    }
    return names;
  }

  group('preview kind', () {
    test('images and plain text are previewable, other types are not', () {
      expect(previewKindFor('holiday.JPG'), PreviewKind.image);
      expect(previewKindFor('logo.png'), PreviewKind.image);
      expect(previewKindFor('notes.md'), PreviewKind.text);
      expect(previewKindFor('export.csv'), PreviewKind.text);
      expect(previewKindFor('README'), PreviewKind.unsupported);
      expect(previewKindFor('report.pdf'), PreviewKind.unsupported);
      expect(previewKindFor('archive.zip'), PreviewKind.unsupported);
      expect(previewKindFor('trailing.'), PreviewKind.unsupported);
    });
  });

  group('preview loading', () {
    test(
      'a text file is downloaded into a scratch copy that is deleted',
      () async {
        var downloads = 0;
        final loader = PreviewLoader(
          tempRoot: root,
          download: (destination) async {
            downloads++;
            await File(destination).writeAsString('hello from the server');
          },
        );

        final content = await loader.load(
          fileId: 'file-1',
          revisionId: 'rev-1',
          name: 'notes.txt',
          sizeBytes: 21,
        );

        expect(downloads, 1);
        expect(content.kind, PreviewKind.text);
        expect(content.text, 'hello from the server');
        expect(content.fromOfflineCopy, isFalse);
        expect(content.truncated, isFalse);
        // No decrypted scratch copy survives the read.
        expect(await scratchFiles(), isEmpty);
      },
    );

    test(
      'an existing device copy is used without any network download',
      () async {
        final offline = File(p.join(root.path, 'offline.bin'));
        await offline.writeAsString('already on this device');
        var downloads = 0;
        final loader = PreviewLoader(
          tempRoot: Directory(p.join(root.path, 'scratch')),
          lookupOfflineCopy: (fileId, revisionId) {
            expect(fileId, 'file-1');
            expect(revisionId, 'rev-1');
            return offline;
          },
          download: (destination) async {
            downloads++;
          },
        );

        final content = await loader.load(
          fileId: 'file-1',
          revisionId: 'rev-1',
          name: 'notes.md',
          sizeBytes: 22,
        );

        expect(
          downloads,
          0,
          reason: 'a device copy must not touch the network',
        );
        expect(content.fromOfflineCopy, isTrue);
        expect(content.text, 'already on this device');
      },
    );

    test('an unsupported type is refused before any download', () async {
      var downloads = 0;
      final loader = PreviewLoader(
        tempRoot: root,
        download: (destination) async {
          downloads++;
        },
      );

      final content = await loader.load(
        fileId: 'file-1',
        revisionId: 'rev-1',
        name: 'report.pdf',
        sizeBytes: 1024,
      );

      expect(downloads, 0);
      expect(content.hasPreview, isFalse);
      expect(content.message, unsupportedPreviewMessage);
    });

    test(
      'a file over the preview limit is refused before any download',
      () async {
        var downloads = 0;
        final loader = PreviewLoader(
          tempRoot: root,
          download: (destination) async {
            downloads++;
          },
        );

        final content = await loader.load(
          fileId: 'file-1',
          revisionId: 'rev-1',
          name: 'huge.png',
          sizeBytes: previewImageByteLimit + 1,
        );

        expect(downloads, 0, reason: 'an oversized file must not be fetched');
        expect(content.hasPreview, isFalse);
        expect(content.message, contains('too large'));
      },
    );

    test(
      'long text is cut at the character limit and marked truncated',
      () async {
        final text = 'a' * (previewTextCharLimit + 5000);
        final loader = PreviewLoader(
          tempRoot: root,
          download: (destination) async {
            await File(destination).writeAsString(text);
          },
        );

        final content = await loader.load(
          fileId: 'file-1',
          revisionId: 'rev-1',
          name: 'big.log',
          sizeBytes: text.length,
        );

        expect(content.kind, PreviewKind.text);
        expect(content.text!.length, previewTextCharLimit);
        expect(content.truncated, isTrue);
        expect(await scratchFiles(), isEmpty);
      },
    );

    test('malformed UTF-8 still renders without throwing', () async {
      final loader = PreviewLoader(
        tempRoot: root,
        download: (destination) async {
          await File(destination).writeAsBytes(
            Uint8List.fromList(<int>[0x68, 0x69, 0xff, 0xfe, 0x21]),
          );
        },
      );

      final content = await loader.load(
        fileId: 'file-1',
        revisionId: 'rev-1',
        name: 'notes.txt',
        sizeBytes: 5,
      );

      expect(content.kind, PreviewKind.text);
      expect(content.text, startsWith('hi'));
      expect(content.text, endsWith('!'));
    });

    test('image bytes are returned for the page to decode', () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
        'IQAAAABJRU5ErkJggg==',
      );
      final loader = PreviewLoader(
        tempRoot: root,
        download: (destination) async {
          await File(destination).writeAsBytes(png);
        },
      );

      final content = await loader.load(
        fileId: 'file-1',
        revisionId: 'rev-1',
        name: 'pixel.png',
        sizeBytes: png.length,
      );

      expect(content.kind, PreviewKind.image);
      expect(content.imageBytes, isNotNull);
      expect(content.byteLength, png.length);
      expect(await scratchFiles(), isEmpty);
    });

    test('a failed download leaves no scratch copy behind', () async {
      final loader = PreviewLoader(
        tempRoot: root,
        download: (destination) async {
          await File(destination).writeAsString('half a file');
          throw StateError('connection closed');
        },
      );

      await expectLater(
        loader.load(
          fileId: 'file-1',
          revisionId: 'rev-1',
          name: 'notes.txt',
          sizeBytes: 100,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await scratchFiles(), isEmpty);
    });

    test('an empty image is reported instead of shown', () async {
      final loader = PreviewLoader(
        tempRoot: root,
        download: (destination) async {
          await File(destination).writeAsBytes(Uint8List(0));
        },
      );

      await expectLater(
        loader.load(
          fileId: 'file-1',
          revisionId: 'rev-1',
          name: 'empty.png',
          sizeBytes: 0,
        ),
        throwsA(isA<PreviewLoadException>()),
      );
    });

    test(
      'scratch leftovers from an interrupted run are removed on first use',
      () async {
        final stale = File(p.join(root.path, 'stale.part'));
        await stale.writeAsString('decrypted leftover');
        await stale.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 30)),
        );

        final loader = PreviewLoader(
          tempRoot: root,
          download: (destination) async {
            await File(destination).writeAsString('fresh');
          },
        );
        await loader.load(
          fileId: 'file-1',
          revisionId: 'rev-1',
          name: 'notes.txt',
          sizeBytes: 5,
        );

        expect(await stale.exists(), isFalse);
        expect(await scratchFiles(), isEmpty);
      },
    );

    test(
      'purge keeps a scratch file that a running preview may still need',
      () async {
        final fresh = File(p.join(root.path, 'fresh.part'));
        await fresh.writeAsString('in flight');
        final stale = File(p.join(root.path, 'stale.part'));
        await stale.writeAsString('leftover');
        await stale.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 30)),
        );

        final removed = await PreviewLoader.purgeStalePreviews(root);

        expect(removed, 1);
        expect(await fresh.exists(), isTrue);
        expect(await stale.exists(), isFalse);
      },
    );
  });
}
