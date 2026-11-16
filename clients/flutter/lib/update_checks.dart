import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'updater.dart';

/// A prompt acknowledges presentation (including Later/dismiss), not installation.
/// Returning false means there was no usable UI and the offer must be retried.
typedef UpdatePrompt<T> = Future<bool> Function(T);

/// Shared desktop/Android automatic-check lifecycle. Failed feed reads and
/// unavailable prompts never consume the daily gate.
class AutomaticUpdateChecks<T> {
  AutomaticUpdateChecks({
    required this.check,
    required this.prompt,
    required this.isSkipped,
  });

  final Future<T?> Function() check;
  final UpdatePrompt<T> prompt;
  final Future<bool> Function(T, SharedPreferences) isSkipped;
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;
  bool _pending = false;
  bool _retryRequested = false;

  void start() {
    if (_disposed || _timer != null) return;
    unawaited(run(startup: true));
    _timer = Timer.periodic(const Duration(hours: 24), (_) => unawaited(run()));
  }

  /// Called after onboarding has published its replacement UI. A confirmation
  /// racing an in-flight check is remembered until that attempt releases its lock.
  Future<void> retryPending() async {
    if (_disposed || !_pending) return;
    if (_busy) {
      _retryRequested = true;
      return;
    }
    await run(startup: true);
  }

  Future<void> run({bool startup = false}) async {
    if (_busy || _disposed) return;
    _busy = true;
    _pending = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || !(prefs.getBool('updateAutoCheck') ?? true)) return;
      final now = DateTime.now();
      final last = DateTime.tryParse(prefs.getString('updateLastCheck') ?? '');
      if (!startup &&
          last != null &&
          now.difference(last) < const Duration(hours: 24)) {
        _pending = false;
        return;
      }
      final info = await check();
      if (_disposed || !(prefs.getBool('updateAutoCheck') ?? true)) return;
      if (info != null) {
        final skipped = await isSkipped(info, prefs);
        if (_disposed || !(prefs.getBool('updateAutoCheck') ?? true)) return;
        if (!skipped && !await prompt(info)) return;
      }
      if (_disposed) return;
      await prefs.setString(
          'updateLastCheck', DateTime.now().toIso8601String());
      _pending = false;
    } catch (_) {
      // Offline/feed/UI failures must never prevent using the client.
    } finally {
      _busy = false;
      final retry = _retryRequested;
      _retryRequested = false;
      if (retry && _pending && !_disposed) await retryPending();
    }
  }

  /// Manual checks ignore opt-out and deferral but share the automatic lock.
  Future<void> manual(Future<void> Function() action) async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      await action();
    } finally {
      _busy = false;
      final retry = _retryRequested;
      _retryRequested = false;
      if (retry && _pending && !_disposed) await retryPending();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}

class UpdateChecks extends AutomaticUpdateChecks<UpdateInfo> {
  UpdateChecks({required super.check, required super.prompt})
      : super(
          isSkipped: (info, prefs) async =>
              prefs.getString('updateSkippedVersion') == info.version,
        );
}
