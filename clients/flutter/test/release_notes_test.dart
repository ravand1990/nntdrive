import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nntdrive/updater.dart';

Map<String, dynamic> release(
  String tag,
  String body, {
  bool prerelease = false,
  bool draft = false,
  List<Map<String, dynamic>> assets = const [],
}) =>
    {
      'tag_name': tag,
      'body': body,
      'prerelease': prerelease,
      'draft': draft,
      'assets': assets,
    };

void main() {
  test('versions are ordered numerically, not as strings', () {
    expect(compareVersions('0.10.0', '0.9.0'), 1);
    expect(compareVersions('0.9.0', '0.10.0'), -1);
    expect(compareVersions('v1.2.3', '1.2.3'), 0);
    expect(compareVersions('1.2.3-beta.1', '1.2.3'), 0);
    expect(isNewerVersion('0.10.0', '0.9.0'), isTrue);
    expect(isNewerVersion('nightly', '0.9.0'), isFalse);
    expect(parseVersionParts('nightly'), isNull);
    expect(parseVersionParts('0.1'), [0, 1, 0]);
  });

  test('release tags are normalized and unparseable tags are ignored', () {
    expect(releaseTag(release('v0.9.0', 'notes')), '0.9.0');
    expect(releaseTag(release('0.9.0', 'notes')), '0.9.0');
    expect(releaseTag(release('nightly', 'notes')), isNull);
    expect(releaseTag(const {}), isNull);
  });

  test('the newest stable release above the installed version is the target', () {
    final feed = [
      release('v0.9.0', 'nine'),
      release('v0.10.0', 'ten'),
      release('v0.11.0-rc.1', 'prerelease', prerelease: true),
      release('v0.8.0', 'eight'),
      release('nightly', 'not a version'),
    ];
    final target = selectTargetRelease(feed, '0.6.0');
    expect(target?['tag_name'], 'v0.10.0');
  });

  test('a dev build newer than every release is up to date', () {
    final feed = [release('v0.9.0', 'nine'), release('v0.8.0', 'eight')];
    expect(selectTargetRelease(feed, '0.10.0'), isNull);
    expect(selectTargetRelease(feed, '0.9.0'), isNull);
  });

  test('notes cover every version between installed and latest', () {
    final feed = [
      release('v0.10.0', 'Ten changes'),
      release('v0.9.0', 'Nine changes'),
      release('v0.7.0', 'Seven changes'),
      release('v0.6.0', 'Installed version notes'),
      release('v0.5.0', 'Older than installed'),
      release('v0.11.0-beta.1', 'Prerelease changes', prerelease: true),
      release('nightly', 'Nightly changes'),
    ];
    final notes = collectUpgradeNotes(feed, installedVersion: '0.6.0');
    expect(notes.entries.map((e) => e.version).toList(),
        ['0.10.0', '0.9.0', '0.7.0']);
    expect(notes.entries.first.body, 'Ten changes');
    expect(notes.omitted, 0);
    final text = notes.text;
    expect(text.indexOf('0.10.0'), lessThan(text.indexOf('0.9.0')));
    expect(text.indexOf('0.9.0'), lessThan(text.indexOf('0.7.0')));
    expect(text, isNot(contains('Prerelease changes')));
    expect(text, isNot(contains('Older than installed')));
    expect(text, isNot(contains('Installed version notes')));
  });

  test('ordering is numeric so 0.10.0 comes before 0.9.0', () {
    final feed = [
      release('v0.9.0', 'nine'),
      release('v0.10.0', 'ten'),
    ];
    final notes = collectUpgradeNotes(feed, installedVersion: '0.8.0');
    expect(notes.entries.map((e) => e.version).toList(), ['0.10.0', '0.9.0']);
  });

  test('empty bodies are skipped and never produce blank sections', () {
    final feed = [
      release('v0.10.0', '   '),
      release('v0.9.0', 'Nine changes'),
      release('v0.8.0', ''),
    ];
    final notes = collectUpgradeNotes(feed, installedVersion: '0.7.0');
    expect(notes.entries.map((e) => e.version).toList(), ['0.9.0']);
    expect(notes.text.trim(), 'Version 0.9.0\n\nNine changes');
  });

  test('a single release aggregates cleanly', () {
    final notes = collectUpgradeNotes(
      [release('v0.9.0', 'Nine changes')],
      installedVersion: '0.8.0',
    );
    expect(notes.entries, hasLength(1));
    expect(notes.text, 'Version 0.9.0\n\nNine changes');
  });

  test('a duplicate version is only shown once', () {
    final feed = [
      release('v0.9.0', 'Nine changes'),
      release('0.9.0', 'Nine changes again'),
    ];
    final notes = collectUpgradeNotes(feed, installedVersion: '0.8.0');
    expect(notes.entries, hasLength(1));
  });

  test('no newer release means no notes', () {
    final notes = collectUpgradeNotes(
      [release('v0.8.0', 'eight'), release('v0.7.0', 'seven')],
      installedVersion: '0.9.0',
    );
    expect(notes.isEmpty, isTrue);
    expect(notes.text, isEmpty);
  });

  test('caps drop the oldest sections and report how many', () {
    final feed = [
      for (var minor = 10; minor >= 5; minor--)
        release('v0.$minor.0', 'changes in 0.$minor.0'),
    ];
    final notes = collectUpgradeNotes(
      feed,
      installedVersion: '0.4.0',
      maxSections: 2,
    );
    expect(notes.entries.map((e) => e.version).toList(), ['0.10.0', '0.9.0']);
    expect(notes.omitted, 4);
    expect(notes.text, contains('4 older releases not shown.'));
  });

  test('a very long body is shortened with a marker', () {
    final notes = collectUpgradeNotes(
      [release('v0.9.0', 'x' * 500)],
      installedVersion: '0.8.0',
      maxBodyChars: 100,
    );
    expect(notes.entries.single.body.length, lessThanOrEqualTo(101));
    expect(notes.entries.single.body, endsWith('…'));
  });

  test('the release feed is read page by page', () async {
    final requested = <String>[];
    final fullPage = [
      for (var minor = 99; minor > 39; minor--)
        release('v0.99.$minor', 'changes in 0.99.$minor'),
      for (var minor = 60; minor >= 21; minor--)
        release('v0.$minor.0', 'changes in 0.$minor.0'),
    ];
    expect(fullPage, hasLength(100));
    final client = MockClient((request) async {
      requested.add(request.url.toString());
      expect(request.url.queryParameters['per_page'], '100');
      final page = request.url.queryParameters['page'];
      if (page == '1') return http.Response(jsonEncode(fullPage), 200);
      if (page == '2') {
        return http.Response(
            jsonEncode([release('v0.0.9', 'the oldest changes')]), 200);
      }
      return http.Response('[]', 200);
    });
    final updater = Updater(
      const UpdateConfig(repo: 'ravand1990/nntdrive', token: ''),
      client: client,
    );
    final feed = await updater.fetchReleases();
    expect(feed, hasLength(101));
    expect(feed.last['tag_name'], 'v0.0.9');
    expect(requested, hasLength(2));
    expect(requested[0], contains('page=1'));
    expect(requested[1], contains('page=2'));

    final notes = collectUpgradeNotes(
      feed,
      installedVersion: '0.0.1',
      maxSections: 200,
    );
    expect(notes.text, contains('the oldest changes'));
  });

  test('a 404 keeps its repository guidance', () async {
    final updater = Updater(
      const UpdateConfig(repo: 'ravand1990/missing', token: ''),
      client: MockClient((_) async => http.Response('{}', 404)),
    );
    await expectLater(
      updater.fetchReleases(),
      throwsA(isA<UpdateException>().having((e) => e.message, 'message',
          contains('Could not read the latest release'))),
    );
  });

  test('a 401 keeps its token guidance', () async {
    final updater = Updater(
      const UpdateConfig(repo: 'ravand1990/nntdrive', token: 'bad'),
      client: MockClient((_) async => http.Response('{}', 401)),
    );
    await expectLater(
      updater.fetchReleases(),
      throwsA(isA<UpdateException>().having(
          (e) => e.message, 'message', contains('access token was rejected'))),
    );
  });
}
