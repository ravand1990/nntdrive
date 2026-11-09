import 'dart:async';

/// Platform-independent close/restore/quit policy, exercised with a fake host.
abstract class DesktopHost {
  Future<bool> initialize(void Function() close, void Function(String) action);
  Future<bool> trayAvailable();
  Future<void> menu(String status,
      {required bool canPause, required bool paused});
  Future<void> hide();
  Future<void> show();
  Future<void> destroy();
}

class DesktopLifecycle {
  DesktopLifecycle(
      {required this.host,
      required this.drain,
      required this.quit,
      required this.togglePause,
      required this.onError});
  final DesktopHost host;
  final Future<void> Function() drain;
  final Future<void> Function() quit;
  final Future<void> Function() togglePause;
  final void Function(String) onError;
  bool ready = false;
  bool hidden = false;
  bool closing = false;
  Future<void>? _quitting;
  Timer? _watchdog;
  Future<void> _updates = Future.value();

  Future<void>? _starting;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    try {
      ready = await host.initialize(() => unawaited(close()), action);
      if (!ready) {
        onError('System tray unavailable. Closing will quit NNTDrive.');
      }
      _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
        if (hidden && !closing) unawaited(checkRestorePath());
      });
    } catch (_) {
      ready = false;
      onError('System tray unavailable. Closing will quit NNTDrive.');
    }
  }

  // Serialize menu writes so a stale async update cannot replace the new state.
  Future<void> update(String status,
      {required bool canPause, required bool paused}) {
    _updates = _updates.then((_) async {
      if (!ready) return;
      try {
        await host.menu(status, canPause: canPause, paused: paused);
      } catch (_) {
        ready = false;
        await restore();
        onError('System tray failed. Closing will quit NNTDrive.');
      }
    });
    return _updates;
  }

  Future<void> close() async {
    if (closing) return;
    await _starting;
    await _updates;
    if (closing) return;
    try {
      if (ready && await host.trayAvailable()) {
        if (closing) return;
        await host.hide();
        if (closing) {
          await restore();
          return;
        }
        hidden = true;
        return; // No widget, session, controller or timer is disposed.
      }
    } catch (_) {
      ready = false;
    }
    await requestQuit();
  }

  Future<void> checkRestorePath() async {
    try {
      if (await host.trayAvailable()) return;
    } catch (_) {/* Fail visible. */}
    ready = false;
    await restore();
    if (!hidden) onError('System tray disconnected. NNTDrive was restored.');
  }

  Future<void> restore() async {
    try {
      await host.show();
      hidden = false;
    } catch (_) {
      onError('Could not restore the window. Retry Open NNTDrive or Quit.');
    }
  }

  void action(String key) {
    switch (key) {
      case 'open':
        unawaited(restore());
      case 'pause':
        if (!closing) {
          unawaited(togglePause().catchError((Object _) {
            onError(
                'Could not change sync pause state. Open NNTDrive to retry.');
          }));
        }
      case 'quit':
        unawaited(requestQuit());
    }
  }

  Future<void> requestQuit() => _quitting ??= _quit();

  Future<void> _quit() async {
    closing = true;
    try {
      await _starting;
      _watchdog?.cancel();
      // Keep the window visible during a long drain. A show failure must not
      // bypass key draining or produce an unhandled close-event future.
      await restore();
      await drain();
      await _updates;
      await host.destroy();
      await quit();
    } catch (_) {
      closing = false;
      _quitting = null;
      onError('Could not finish shutdown. NNTDrive remains open; retry Quit.');
    }
  }

  void dispose() => _watchdog?.cancel();
}
