import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/key_rotation.dart';

/// A rotation attempt the tests control: replies in order and records what the
/// dialog actually sent, so no native bridge or HTTP server is involved.
Map<String, dynamic> rotatedReply({String? recoveryCode}) => {
      'ok': true,
      'status': 'rotated',
      'keyfile': {'account_id': 'a', 'epoch': 1, 'retained': [{'epoch': 0}]},
      'epoch': 1,
      'adopted': true,
      if (recoveryCode != null) 'recovery_code': recoveryCode,
    };

void main() {
  group('KeyRotationOutcome', () {
    test('reads a rotation that replaced the recovery kit', () {
      final outcome = KeyRotationOutcome.fromNative(rotatedReply(recoveryCode: 'new-code'));
      expect(outcome.rotated, isTrue);
      expect(outcome.epoch, 1);
      expect(outcome.recoveryCode, 'new-code');
      expect(outcome.keyfileJson, contains('"epoch":1'));
      expect(outcome.needsRecoveryCode, isFalse);
    });

    test('reads a rotation without a stored kit', () {
      final outcome = KeyRotationOutcome.fromNative(rotatedReply());
      expect(outcome.rotated, isTrue);
      expect(outcome.recoveryCode, isNull);
    });

    test('reads the recovery-code request instead of treating it as success', () {
      final outcome = KeyRotationOutcome.fromNative(
          {'ok': true, 'status': 'recovery_code_required', 'kit_epoch': 3, 'adopted': false});
      expect(outcome.rotated, isFalse);
      expect(outcome.needsRecoveryCode, isTrue);
      expect(outcome.kitEpoch, 3);
    });

    test('treats a malformed success as a refusal', () {
      final outcome = KeyRotationOutcome.fromNative({'ok': true, 'status': 'rotated', 'epoch': 1});
      expect(outcome.rotated, isFalse);
      expect(outcome.error, 'the rotated keyfile was incomplete');
    });
  });

  group('offerRotationAfterRevoke', () {
    test('does nothing when the server did not require rotation', () async {
      var confirmed = 0;
      var rotated = 0;
      final result = await offerRotationAfterRevoke(
        DeviceRevokeResult(keyRotationRequired: false),
        confirm: () async {
          confirmed++;
          return true;
        },
        rotate: () async {
          rotated++;
          return true;
        },
      );
      expect(result, isFalse);
      expect(confirmed, 0);
      expect(rotated, 0);
    });

    test('does not rotate when the user declines', () async {
      var rotated = 0;
      final result = await offerRotationAfterRevoke(
        DeviceRevokeResult(keyRotationRequired: true),
        confirm: () async => false,
        rotate: () async {
          rotated++;
          return true;
        },
      );
      expect(result, isFalse);
      expect(rotated, 0);
    });

    test('rotates when the user agrees', () async {
      var rotated = 0;
      final result = await offerRotationAfterRevoke(
        DeviceRevokeResult(keyRotationRequired: true),
        confirm: () async => true,
        rotate: () async {
          rotated++;
          return true;
        },
      );
      expect(result, isTrue);
      expect(rotated, 1);
    });
  });

  group('RotateAccountKeyDialog', () {
    Future<void> pump(WidgetTester tester,
        {required Future<KeyRotationOutcome> Function(String, String?) rotate,
        int? recoveryKitEpoch}) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await showDialog<KeyRotationOutcome>(
                  context: context,
                  builder: (_) => RotateAccountKeyDialog(
                    rotate: rotate,
                    recoveryKitEpoch: recoveryKitEpoch,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks for the recovery code, then shows the new code once', (tester) async {
      final attempts = <(String, String?)>[];
      await pump(tester, rotate: (password, code) async {
        attempts.add((password, code));
        if (code == null) {
          return KeyRotationOutcome.fromNative(
              {'ok': true, 'status': 'recovery_code_required', 'kit_epoch': 0});
        }
        return KeyRotationOutcome.fromNative(rotatedReply(recoveryCode: 'brand-new-code'));
      });

      await tester.enterText(find.byType(TextField).first, 'hunter2-correct');
      await tester.tap(find.text('Rotate'));
      await tester.pumpAndSettle();
      expect(attempts, [('hunter2-correct', null)]);
      expect(find.textContaining('recovery code is needed'), findsOneWidget);

      // The message stays visible while the code is entered, then the dialog
      // reports success and shows the replacement code exactly once.
      await tester.enterText(find.byType(TextField).at(1), 'old-kit-code');
      await tester.tap(find.text('Rotate'));
      await tester.pumpAndSettle();
      expect(attempts.last, ('hunter2-correct', 'old-kit-code'));
      expect(find.text('Account key rotated'), findsOneWidget);
      expect(find.text('brand-new-code'), findsOneWidget);
      expect(find.textContaining('shown only once'), findsOneWidget);
    });

    testWidgets('keeps the dialog open and shows the refusal', (tester) async {
      await pump(tester, rotate: (password, code) async {
        return KeyRotationOutcome.fromNative(
            {'ok': false, 'error': 'the password does not open this keyfile; nothing was rotated'});
      });
      await tester.enterText(find.byType(TextField).first, 'wrong-password');
      await tester.tap(find.text('Rotate'));
      await tester.pumpAndSettle();
      expect(find.text('Rotate the account key'), findsOneWidget);
      expect(find.textContaining('nothing was rotated'), findsOneWidget);

      // A second attempt is still possible, and no success screen appeared.
      await tester.enterText(find.byType(TextField).first, 'right-password');
      await tester.tap(find.text('Rotate'));
      await tester.pumpAndSettle();
      expect(find.text('Account key rotated'), findsNothing);
    });

    testWidgets('requires the code up front when the account has a kit', (tester) async {
      final attempts = <(String, String?)>[];
      await pump(tester,
          recoveryKitEpoch: 2,
          rotate: (password, code) async {
            attempts.add((password, code));
            return KeyRotationOutcome.fromNative(rotatedReply(recoveryCode: 'fresh'));
          });
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.enterText(find.byType(TextField).first, 'password');
      await tester.tap(find.text('Rotate'));
      await tester.pumpAndSettle();
      expect(attempts, isEmpty, reason: 'rotation ran without the recovery code');
      expect(find.textContaining('Enter the recovery code'), findsOneWidget);
    });

    testWidgets('reports a completed rotation to the caller', (tester) async {
      KeyRotationOutcome? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<KeyRotationOutcome>(
                  context: context,
                  builder: (_) => RotateAccountKeyDialog(
                    rotate: (password, code) async =>
                        KeyRotationOutcome.fromNative(rotatedReply()),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'password');
      await tester.tap(find.text('Rotate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.rotated, isTrue);
      expect(result!.keyfileJson, contains('"epoch":1'));
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
