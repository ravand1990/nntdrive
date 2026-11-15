import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';

/// These tests use a real loopback HTTP server on purpose: the point is the
/// exact request a rewind sends (encoded date, scope, confirm payload) and the
/// exact JSON it accepts back. Never a widget binding — that would install an
/// HTTP override and this fixture would silently stop proving anything.
void main() {
  test('a rewind preview encodes its date, scope and paging cursor', () async {
    final seen = <Uri>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seen.add(request.uri);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'scope': 'folder-1',
          'before': '2026-11-08T23:59:59.000Z',
          'counts': {
            'rewind': 1,
            'unchanged': 3,
            'created_after': 2,
            'pending_references': 1,
          },
          'items': [
            {
              'id': 'file-1',
              'parent_id': 'folder-1',
              'name_enc': 'sealed',
              'current_version': 'rev-now',
              'target_revision': 'rev-old',
              'current_size': 20,
              'target_size': 10,
              'target_created_at': '2026-11-01T10:00:00Z',
            }
          ],
          'next': 'file-1',
        }));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final api = ApiClient(
        baseUrl: 'http://${server.address.host}:${server.port}', token: 't');
    final preview = await api.rewindPreview(
      scopeId: 'folder-1',
      before: DateTime.utc(2026, 11, 8, 23, 59, 59),
      after: 'file-0',
    );

    expect(seen, hasLength(1));
    expect(seen.single.path, '/api/v1/rewind/preview');
    expect(seen.single.queryParameters['before'], '2026-11-08T23:59:59.000Z');
    expect(seen.single.queryParameters['scope'], 'folder-1');
    expect(seen.single.queryParameters['after'], 'file-0');

    expect(preview.counts.rewind, 1);
    expect(preview.counts.unchanged, 3);
    expect(preview.counts.createdAfter, 2);
    expect(preview.counts.pendingReferences, 1);
    expect(preview.items.single.targetRevision, 'rev-old');
    expect(preview.items.single.nameEnc, 'sealed');
    expect(preview.next, 'file-1');
    expect(preview.scopeId, 'folder-1');
  });

  test('applying confirms only the previewed files', () async {
    late Map<String, dynamic> body;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'applied': 1,
          'unchanged': 0,
          'failed': [
            {'id': 'file-2', 'reason': 'the file changed; preview the rewind again'}
          ],
        }));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final api = ApiClient(
        baseUrl: 'http://${server.address.host}:${server.port}', token: 't');
    final result = await api.rewind(
      before: DateTime.utc(2026, 11, 8, 23, 59, 59),
      items: [
        RewindItem('file-1', 'folder-1', 'sealed', 'rev-now', 'rev-old', 20,
            10, DateTime.utc(2026, 11, 1)),
        RewindItem('file-2', null, 'sealed-2', null, 'rev-old-2', 5, 4, null),
      ],
    );

    expect(body['before'], '2026-11-08T23:59:59.000Z');
    expect(body['scope'], isNull, reason: 'account-wide when no folder is set');
    expect(body['items'], [
      {'id': 'file-1', 'target_revision': 'rev-old'},
      {'id': 'file-2', 'target_revision': 'rev-old-2'},
    ]);
    expect(result.applied, 1);
    expect(result.failed.single.id, 'file-2');
    expect(result.failed.single.reason, contains('preview the rewind again'));
  });
}
