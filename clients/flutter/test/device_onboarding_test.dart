import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/device_onboarding.dart';
import 'package:nntdrive/file_rename.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Naming extends DeviceNaming {
  _Naming()
    : super(
        api: ApiClient(baseUrl: 'http://unused'),
        handle: 73,
        server: 'http://unused',
        accountId: 'account',
      );
  AccountRoot root = AccountRoot(
    rootId: 'root-record',
    kind: 'device',
    nodeId: 'root',
    nameEnc: 'sealed',
    deviceId: 'device',
    deviceName: 'Old label',
  );
  Completer<AccountRoot>? suspended;
  bool fail = false;
  bool collide = false;
  final names = <String>[];
  List<DeviceSpaceName> spaces = [];
  @override
  Future<List<DeviceSpaceName>> existingSpaces() async => spaces;
  @override
  String collisionKey(String name) => name.toLowerCase();
  @override
  Future<AccountRoot> currentRoot() async {
    if (fail) throw StateError('private native diagnostic');
    return suspended == null ? root : await suspended!.future;
  }

  @override
  Future<void> confirm(AccountRoot root, String name) async {
    if (collide) {
      throw RenameFailure(
        'A file or folder with this name already exists. Choose another name.',
      );
    }
    names.add(name);
  }
}

void main() {
  late _Naming naming;
  late SessionOperations operations;
  var ready = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    naming = _Naming();
    operations = SessionOperations();
    ready = 0;
  });
  Widget page({bool force = false}) => MaterialApp(
    home: DeviceOnboardingPage(
      naming: naming,
      operations: operations,
      onReady: () async {
        ready++;
      },
      onSignOut: () {},
      force: force,
      defaultName: () async => 'Family laptop',
    ),
  );

  testWidgets(
    'suggests an editable default and requires explicit valid confirmation',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('Family laptop'), findsOneWidget);
      expect(ready, 0);
      expect(naming.names, isEmpty);
      await tester.enterText(find.byType(TextField), 'NUL');
      await tester.tap(find.text('Confirm device name'));
      await tester.pumpAndSettle();
      expect(find.text('This name is reserved on Windows.'), findsOneWidget);
      expect(ready, 0);
      await tester.enterText(find.byType(TextField), 'My laptop');
      naming.collide = true;
      await tester.tap(find.text('Confirm device name'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Choose another name'), findsOneWidget);
      expect(ready, 0);
      await tester.tap(find.text('Reload'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'My laptop');
      expect(find.textContaining('Choose another name'), findsOneWidget);
      naming.collide = false;
      await tester.enterText(find.byType(TextField), 'My laptop 2');
      await tester.tap(find.text('Confirm device name'));
      await tester.pumpAndSettle();
      expect(naming.names, ['My laptop 2']);
      expect(ready, 1);
    },
  );

  testWidgets('collision is visible and unused suggestion completes without reload', (tester) async {
    naming.spaces = const [
      DeviceSpaceName('other', 'FAMILY LAPTOP'),
      DeviceSpaceName('another', 'Family laptop (2)'),
      DeviceSpaceName('root', 'Old label'),
    ];
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Family laptop (3)');
    expect(find.text('FAMILY LAPTOP'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Family laptop');
    await tester.pump();
    expect(find.text('FAMILY LAPTOP · Name already in use'), findsOneWidget);
    await tester.ensureVisible(find.text('Suggest an unused name'));
    await tester.tap(find.text('Suggest an unused name'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm device name'));
    await tester.tap(find.text('Confirm device name'));
    await tester.pumpAndSettle();
    expect(naming.names, ['Family laptop (3)']);
    expect(ready, 1);
  });

  testWidgets(
    'existing identity resumes once, explicit rename never skips prompt',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(naming.key(naming.root), true);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(ready, 1);
      await tester.pumpWidget(const SizedBox());
      ready = 0;
      await tester.pumpWidget(page(force: true));
      await tester.pumpAndSettle();
      expect(ready, 0);
      expect(find.text('Old label'), findsOneWidget);
      expect(
        find.textContaining('Moving legacy folders is a separate'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'initialization failure stays blocked without diagnostic leakage',
    (tester) async {
      naming.fail = true;
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Uploads and sync remain blocked'),
        findsOneWidget,
      );
      expect(find.textContaining('private native diagnostic'), findsNothing);
      expect(ready, 0);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    },
  );

  testWidgets('session drain waits for active setup but not idle user input', (
    tester,
  ) async {
    naming.suspended = Completer<AccountRoot>();
    await tester.pumpWidget(page());
    await tester.pump();
    var drained = false;
    final drain = operations.drain(naming.handle).then((_) {
      drained = true;
    });
    await tester.pump();
    expect(drained, false);
    naming.suspended!.complete(naming.root);
    await tester.pumpAndSettle();
    await drain;
    expect(drained, true);
    await tester.tap(find.text('Confirm device name'));
    await tester.pumpAndSettle();
    expect(naming.names, isEmpty);
    expect(ready, 0);
  });
}
