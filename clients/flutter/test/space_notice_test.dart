import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/space_notice.dart';

AccountRoot _device({String? name = 'Workstation', bool revoked = false}) =>
    AccountRoot(
        rootId: 'r2',
        kind: 'device',
        nodeId: 'n2',
        nameEnc: 'x',
        deviceId: 'd1',
        deviceName: name,
        deviceRevoked: revoked,
        stale: true);

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('an offline space banner shows the conflict explanation',
      (tester) async {
    final root = _device();
    await _pump(tester,
        SpaceWriteNotice(root: root, message: staleSpaceWriteNotice(root)!));

    expect(find.byKey(const ValueKey('space-write-notice')), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(find.textContaining('conflict copy'), findsOneWidget);
  });

  testWidgets('a revoked space banner uses the revoked icon', (tester) async {
    final root = _device(name: 'Old tablet', revoked: true);
    await _pump(tester,
        SpaceWriteNotice(root: root, message: staleSpaceWriteNotice(root)!));

    expect(find.byIcon(Icons.link_off), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);
    expect(find.textContaining('was revoked'), findsOneWidget);
  });
}
