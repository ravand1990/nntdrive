import 'dart:async';

/// UI-isolate ownership of native futures. Closing never cancels a callback or
/// drops a key while a worker may still be using it. No secrets are stored here.
class SessionOperations {
  final _active = <int, Set<Future<void>>>{};
  final _closing = <int>{};

  Future<T> run<T>(int handle, Future<T> Function() action) async {
    if (_closing.contains(handle)) throw StateError('Session is closing');
    final done = Completer<void>();
    final active = _active.putIfAbsent(handle, () => {});
    active.add(done.future);
    try {
      return await action();
    } finally {
      active.remove(done.future);
      done.complete();
      if (active.isEmpty) _active.remove(handle);
    }
  }

  Future<void> drain(int handle) async {
    _closing.add(handle); // Synchronous admission stop, before the first await.
    await Future.wait(_active[handle]?.toList() ?? <Future<void>>[]);
  }
}
