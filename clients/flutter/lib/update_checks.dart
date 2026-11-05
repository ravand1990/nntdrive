import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'updater.dart';

/// Best-effort automatic checks, independent of the deferred-version prompt.
class UpdateChecks {
  UpdateChecks({required this.check, required this.prompt});

  final Future<UpdateInfo?> Function() check;
  final Future<void> Function(UpdateInfo) prompt;
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  void start() {
    if (_disposed || _timer != null) return;
    unawaited(run(startup: true));
    _timer = Timer.periodic(const Duration(hours: 24), (_) => unawaited(run()));
  }

  Future<void> run({bool startup = false}) async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || !(prefs.getBool('updateAutoCheck') ?? true)) return;
      final now = DateTime.now();
      final last = DateTime.tryParse(prefs.getString('updateLastCheck') ?? '');
      if (!startup &&
          last != null &&
          now.difference(last) < const Duration(hours: 24)) {
        return;
      }
      await prefs.setString('updateLastCheck', now.toIso8601String());
      final info = await check();
      if (_disposed ||
          info == null ||
          !(prefs.getBool('updateAutoCheck') ?? true)) {
        return;
      }
      if (prefs.getString('updateSkippedVersion') == info.version) return;
      await prompt(info);
    } catch (_) {
      // Offline/feed failures must never prevent using the client.
    } finally {
      _busy = false;
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
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
