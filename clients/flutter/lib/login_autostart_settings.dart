import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'login_autostart.dart';

/// Install/user-scoped state: never reads account data or unlocks a vault.
class LoginAutostartSettings extends ChangeNotifier {
  LoginAutostartSettings({
    required this.prefs,
    required this.registration,
    required this.executable,
  }) : enabled = prefs.getBool(loginAutostartPreferenceKey) ?? false;

  final SharedPreferences prefs;
  final LoginAutostart registration;
  final String executable;
  bool enabled;
  bool busy = false;
  String? error;
  bool? _retryChoice;
  bool _disposed = false;
  bool get supported => registration.supported;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (busy || _disposed || !supported) return;
    busy = true;
    error = null;
    _retryChoice = null;
    _changed();
    try {
      // Repair a remembered opt-in after an update relocates the executable.
      if (prefs.getBool(loginAutostartPreferenceKey) == true) {
        await registration.apply(enabled: true, executable: executable);
      }
      enabled = await registration.isEnabled();
    } catch (_) {
      error = 'Could not check or restore login startup. Retry to check again.';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<String?> setEnabled(bool choice) async {
    if (_disposed || busy) return 'Login startup is busy. Try again.';
    if (!supported) {
      return 'Login startup is available on Windows and Linux only.';
    }
    busy = true;
    error = null;
    _retryChoice = choice;
    _changed();
    try {
      await registration.apply(enabled: choice, executable: executable);
      enabled = await registration.isEnabled();
      if (enabled != choice) throw StateError('Login item did not change');
      if (!await prefs.setBool(loginAutostartPreferenceKey, choice)) {
        throw StateError('Preference was not saved');
      }
      _retryChoice = null;
    } catch (_) {
      error = 'Could not save login startup. Retry to apply your choice again.';
    } finally {
      busy = false;
      _changed();
    }
    return error;
  }

  Future<void> retry() async {
    final choice = _retryChoice;
    if (choice == null) {
      await initialize();
    } else {
      await setEnabled(choice);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class LoginAutostartControl extends StatelessWidget {
  const LoginAutostartControl({super.key, required this.settings});
  final LoginAutostartSettings settings;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Start NNTDrive when I sign in'),
          subtitle: Text(
            settings.supported
                ? 'Starts at OS login, locked. Your password is still required.'
                : 'Login startup is available on Windows and Linux only.',
          ),
          value: settings.supported && settings.enabled,
          onChanged: settings.supported && !settings.busy
              ? (value) {
                  settings.setEnabled(value);
                }
              : null,
        ),
        if (settings.busy) const Text('Checking or saving login startup…'),
        if (settings.error != null) ...[
          Text(
            settings.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: settings.busy ? null : settings.retry,
              child: const Text('Retry login startup'),
            ),
          ),
        ],
      ],
    ),
  );
}
