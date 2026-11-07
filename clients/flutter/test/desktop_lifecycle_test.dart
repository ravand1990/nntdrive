import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/desktop_lifecycle.dart';
import 'package:nntdrive/session_operations.dart';

class FakeHost extends DesktopHost {
  final events = <String>[];
  bool available = true;
  bool failMenu = false;
  bool failHide = false;
  bool failShow = false;
  bool failInitialize = false;
  @override
  Future<bool> initialize(
      void Function() close, void Function(String) action) async {
    if (failInitialize) throw StateError('plugin unavailable');
    return available;
  }

  @override
  Future<bool> trayAvailable() async => available;
  @override
  Future<void> menu(String status,
      {required bool canPause, required bool paused}) async {
    if (failMenu) throw StateError('tray disconnected');
    events.add('$status:$canPause:$paused');
  }

  @override
  Future<void> hide() async {
    if (failHide) throw StateError('hide failed');
    events.add('hide');
  }

  @override
  Future<void> show() async {
    if (failShow) throw StateError('window unavailable');
    events.add('show');
  }

  @override
  Future<void> destroy() async {
    events.add('destroy');
  }
}

void main() {
  test('close retains the live session; restore and pause do not drain',
      () async {
    final host = FakeHost();
    final errors = <String>[];
    final lifecycle = DesktopLifecycle(
        host: host,
        drain: () async {
          host.events.add('drain');
        },
        quit: () async {
          host.events.add('quit');
        },
        togglePause: () async {
          host.events.add('pause');
        },
        onError: errors.add);
    addTearDown(lifecycle.dispose);
    await lifecycle.start();
    await lifecycle.update('Sync scheduled', canPause: true, paused: false);
    await lifecycle.close();
    expect(lifecycle.hidden, isTrue);
    expect(host.events, ['Sync scheduled:true:false', 'hide']);
    lifecycle.action('pause');
    await lifecycle.restore();
    expect(host.events, containsAllInOrder(['pause', 'show']));
    expect(host.events, isNot(contains('drain')));
    expect(errors, isEmpty);
  });

  for (final failure in ['unavailable', 'hide failure']) {
    test('$failure close drains before quit; repeated quit shares one future',
        () async {
      final host = FakeHost()
        ..available = failure != 'unavailable'
        ..failHide = failure == 'hide failure';
      final drained = Completer<void>();
      final lifecycle = DesktopLifecycle(
          host: host,
          drain: () {
            host.events.add('drain');
            return drained.future;
          },
          quit: () async {
            host.events.add('quit');
          },
          togglePause: () async {},
          onError: (_) {});
      addTearDown(lifecycle.dispose);
      await lifecycle.start();
      final close = lifecycle.close();
      await Future<void>.delayed(Duration.zero);
      final quit1 = lifecycle.requestQuit();
      expect(identical(quit1, lifecycle.requestQuit()), isTrue);
      expect(host.events, ['show', 'drain']);
      drained.complete();
      await close;
      expect(host.events, ['show', 'drain', 'destroy', 'quit']);
    });
  }

  test(
      'tray disappears while hidden: restore, never strand an invisible process',
      () async {
    final host = FakeHost();
    final errors = <String>[];
    final lifecycle = DesktopLifecycle(
        host: host,
        drain: () async {},
        quit: () async {},
        togglePause: () async {},
        onError: errors.add);
    addTearDown(lifecycle.dispose);
    await lifecycle.start();
    await lifecycle.close();
    host.available = false;
    await lifecycle.checkRestorePath();
    expect(lifecycle.hidden, isFalse);
    expect(lifecycle.ready, isFalse);
    expect(host.events, ['hide', 'show']);
    expect(errors.single, contains('restored'));
  });

  test('menu failure fails visible and disables hiding', () async {
    final host = FakeHost();
    final lifecycle = DesktopLifecycle(
        host: host,
        drain: () async {},
        quit: () async {},
        togglePause: () async {},
        onError: (_) {});
    addTearDown(lifecycle.dispose);
    await lifecycle.start();
    await lifecycle.close();
    host.failMenu = true;
    await lifecycle.update('Sync running', canPause: true, paused: false);
    expect(lifecycle.hidden, isFalse);
    expect(lifecycle.ready, isFalse);
  });

  test('initialization failure falls back to drained quit', () async {
    final host = FakeHost()..failInitialize = true;
    final errors = <String>[];
    final lifecycle = DesktopLifecycle(
        host: host,
        drain: () async {
          host.events.add('drain');
        },
        quit: () async {
          host.events.add('quit');
        },
        togglePause: () async {},
        onError: errors.add);
    addTearDown(lifecycle.dispose);
    await lifecycle.start();
    await lifecycle.close();
    expect(host.events, ['show', 'drain', 'destroy', 'quit']);
    expect(errors.single, contains('unavailable'));
  });

  test('restore errors are handled and cannot bypass quit drain', () async {
    final host = FakeHost();
    final errors = <String>[];
    final lifecycle = DesktopLifecycle(
        host: host,
        drain: () async {
          host.events.add('drain');
        },
        quit: () async {
          host.events.add('quit');
        },
        togglePause: () async {},
        onError: errors.add);
    addTearDown(lifecycle.dispose);
    await lifecycle.start();
    await lifecycle.close();
    host.failShow = true;
    await lifecycle.restore();
    expect(lifecycle.hidden, isTrue);
    await lifecycle.requestQuit();
    expect(host.events, ['hide', 'drain', 'destroy', 'quit']);
    expect(errors.every((e) => e.contains('restore')), isTrue);
  });

  test('failed drain never destroys the tray or quits; retry is possible',
      () async {
    final host = FakeHost();
    var attempts = 0;
    final lifecycle = DesktopLifecycle(
        host: host,
        drain: () async {
          if (++attempts == 1) throw StateError('drain failure');
        },
        quit: () async {
          host.events.add('quit');
        },
        togglePause: () async {},
        onError: (_) {});
    addTearDown(lifecycle.dispose);
    await lifecycle.start();
    await lifecycle.requestQuit();
    expect(host.events, ['show']);
    expect(lifecycle.closing, isFalse);
    await lifecycle.requestQuit();
    expect(host.events, ['show', 'show', 'destroy', 'quit']);
  });

  test(
      'session drain blocks admission synchronously, waits for all operations including errors',
      () async {
    final operations = SessionOperations();
    final success = Completer<int>();
    final failure = Completer<int>();
    final first = operations.run(12, () => success.future);
    final second = operations.run(12, () => failure.future);
    final error = expectLater(second, throwsStateError);
    var done = false;
    final drain = operations.drain(12).then((_) => done = true);
    await expectLater(operations.run(12, () async => 9), throwsStateError);
    expect(await operations.run(13, () async => 1), 1);
    success.complete(7);
    expect(await first, 7);
    expect(done, isFalse);
    failure.completeError(StateError('worker failed'));
    await error;
    await drain;
    expect(done, isTrue);
    await operations.drain(12); // Idempotent, no timeout/cancellation shortcut.
  });
}
