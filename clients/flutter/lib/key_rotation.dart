import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';

/// What one rotation attempt did.
///
/// Only these outcomes are possible: a completed rotation (optionally with a
/// replacement recovery kit and its one-time code), a request for the current
/// recovery code because the account stores a kit, or a refusal. Nothing here
/// carries key material — the rotated keyfile stays password-wrapped.
class KeyRotationOutcome {
  KeyRotationOutcome._({this.keyfileJson, this.epoch, this.recoveryCode, this.kitEpoch, this.error});

  /// The rotated, still password-wrapped keyfile. Present only on success.
  final String? keyfileJson;

  /// The new current account-key epoch. Present only on success.
  final int? epoch;

  /// The replacement recovery code, shown once. Present only when the account
  /// stored a kit and the rotation replaced it.
  final String? recoveryCode;

  /// Epoch of the stored kit that must be replaced. Present when the account
  /// needs its current recovery code before it can rotate.
  final int? kitEpoch;

  /// Why the rotation was refused, when the server or bridge said so.
  final String? error;

  bool get rotated => keyfileJson != null && error == null;
  bool get needsRecoveryCode => kitEpoch != null && error == null;

  /// Reads the bridge reply. A successful rotation always carries the new
  /// keyfile; anything else is reported as a refusal instead of being treated
  /// as success.
  factory KeyRotationOutcome.fromNative(Map<String, dynamic> reply) {
    final status = reply['status'];
    if (status == 'rotated') {
      final keyfile = reply['keyfile'];
      final epoch = reply['epoch'];
      if (keyfile is! Map<String, dynamic> || epoch is! int) {
        return KeyRotationOutcome._(error: 'the rotated keyfile was incomplete');
      }
      return KeyRotationOutcome._(
        keyfileJson: jsonEncode(keyfile),
        epoch: epoch,
        recoveryCode: reply['recovery_code'] as String?,
      );
    }
    if (status == 'recovery_code_required') {
      return KeyRotationOutcome._(kitEpoch: reply['kit_epoch'] as int? ?? 0);
    }
    return KeyRotationOutcome._(error: reply['error'] as String? ?? 'the account key was not rotated');
  }

  /// Runs one attempt through the native bridge, mapping a bridge exception to
  /// a refusal so the dialog can show it instead of crashing.
  static Future<KeyRotationOutcome> attempt(
      Future<Map<String, dynamic>> Function(String password, String? recoveryCode) call,
      String password,
      String? recoveryCode) async {
    try {
      return KeyRotationOutcome.fromNative(await call(password, recoveryCode));
    } catch (e) {
      return KeyRotationOutcome._(error: e.toString());
    }
  }
}

/// Asks for confirmation after a device revocation and rotates only when the
/// server asked for it and the user agreed.
///
/// A revoked device keeps reading content sealed under the current account-key
/// epoch until the key is rotated, so the server reports
/// `key_rotation_required` with the revoke. The app must not rotate silently:
/// rotation needs the account password and, when a kit is stored, the current
/// recovery code.
Future<bool> offerRotationAfterRevoke(
  DeviceRevokeResult result, {
  required Future<bool> Function() confirm,
  required Future<bool> Function() rotate,
}) async {
  if (!result.keyRotationRequired) return false;
  if (!await confirm()) return false;
  return rotate();
}

/// Explains what a rotation does and asks whether to start it now.
Future<bool> confirmKeyRotation(BuildContext context) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rotate the account key?'),
      content: const Text(
          'The revoked device can still read files stored before now, because they were '
          'encrypted with the current account key. Rotating the key protects new content '
          'and every later change. You will need your account password, and your recovery '
          'code if this account has a recovery kit.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Rotate now')),
      ],
    ),
  );
  return agreed ?? false;
}

/// Collects the password, then the recovery code when the account needs it,
/// and performs the rotation through `rotate`.
///
/// The dialog never keeps the password or code after it closes, and the new
/// recovery code is shown once with a copy action.
class RotateAccountKeyDialog extends StatefulWidget {
  const RotateAccountKeyDialog({
    super.key,
    required this.rotate,
    this.recoveryKitEpoch,
  });

  /// One rotation attempt: password plus the recovery code when one is needed.
  final Future<KeyRotationOutcome> Function(String password, String? recoveryCode) rotate;

  /// The kit epoch the server already reported, when the caller knows it.
  final int? recoveryKitEpoch;

  @override
  State<RotateAccountKeyDialog> createState() => _RotateAccountKeyDialogState();
}

class _RotateAccountKeyDialogState extends State<RotateAccountKeyDialog> {
  final _password = TextEditingController();
  final _recoveryCode = TextEditingController();
  bool _needsCode = false;
  bool _busy = false;
  String? _error;
  KeyRotationOutcome? _done;

  @override
  void initState() {
    super.initState();
    _needsCode = widget.recoveryKitEpoch != null;
  }

  @override
  void dispose() {
    _password.clear();
    _recoveryCode.clear();
    _password.dispose();
    _recoveryCode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final password = _password.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter your account password.');
      return;
    }
    final code = _needsCode ? _recoveryCode.text.trim() : null;
    if (_needsCode && (code == null || code.isEmpty)) {
      setState(() => _error = 'Enter the recovery code for this account.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await widget.rotate(password, code);
    if (!mounted) return;
    if (outcome.needsRecoveryCode) {
      setState(() {
        _busy = false;
        _needsCode = true;
        _error = 'This account has a recovery kit, so its current recovery code is needed '
            'to replace it for the new key.';
      });
      return;
    }
    if (!outcome.rotated) {
      setState(() {
        _busy = false;
        _error = outcome.error ?? 'The account key was not rotated.';
      });
      return;
    }
    setState(() {
      _busy = false;
      _done = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final done = _done;
    if (done != null) return _success(done);
    return AlertDialog(
      title: const Text('Rotate the account key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your password re-wraps the key for this device. It is not stored.'),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Account password'),
          ),
          if (_needsCode) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _recoveryCode,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Current recovery code'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Rotating…' : 'Rotate'),
        ),
      ],
    );
  }

  Widget _success(KeyRotationOutcome outcome) {
    final code = outcome.recoveryCode;
    return AlertDialog(
      title: const Text('Account key rotated'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('The account now uses key epoch ${outcome.epoch}. Devices that were not '
              'revoked pick up the new key the next time they unlock.'),
          if (code != null) ...[
            const SizedBox(height: 12),
            const Text('Your recovery code was replaced. Store the new one offline now — '
                'it is shown only once and the old code no longer works.'),
            const SizedBox(height: 8),
            SelectableText(code, style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              icon: const Icon(Icons.copy),
              label: const Text('Copy recovery code'),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(context, outcome), child: const Text('Done')),
      ],
    );
  }
}
