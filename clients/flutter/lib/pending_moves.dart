// Durable offline move queue (#95).
//
// A move chosen while the server cannot be reached is kept on this device and
// applied on the next unlock or sync. Entries store only opaque node IDs and
// sealed-name ciphertext: nothing here is readable without the account key, and
// no plaintext path or filename is written. Replaying runs the same guarded
// move as an online attempt, so a destination collision or a source that
// changed on another device stops safely instead of overwriting anything.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'file_move.dart';
import 'file_rename.dart';
import 'native.dart';

/// A device that stays offline must not grow an unbounded local queue.
const pendingMoveLimit = 20;

/// Largest destination listing accepted while replaying a queued move.
const pendingMoveListingLimit = 4096;

/// One queued move: the source snapshot taken when the online attempt failed.
class PendingMove {
  const PendingMove({
    required this.entryId,
    required this.fileId,
    required this.sourceParentId,
    required this.sourceNameEnc,
    required this.destinationParentId,
    required this.isDir,
    required this.queuedAt,
    this.blockedReason,
  });

  final String entryId;
  final String fileId;
  final String? sourceParentId;

  /// Sealed name at queue time. Ciphertext only, exactly as it came from the
  /// server: replay re-uses it as the guard's source-name snapshot.
  final String sourceNameEnc;
  final String? destinationParentId;
  final bool isDir;
  final DateTime queuedAt;

  /// Plain-language reason this entry stopped retrying automatically.
  final String? blockedReason;

  Map<String, dynamic> toJson() => {
        'entryId': entryId,
        'fileId': fileId,
        'sourceParentId': sourceParentId,
        'sourceNameEnc': sourceNameEnc,
        'destinationParentId': destinationParentId,
        'isDir': isDir,
        'queuedAt': queuedAt.toIso8601String(),
        'blockedReason': blockedReason,
      };

  PendingMove blocked(String reason) => PendingMove(
        entryId: entryId,
        fileId: fileId,
        sourceParentId: sourceParentId,
        sourceNameEnc: sourceNameEnc,
        destinationParentId: destinationParentId,
        isDir: isDir,
        queuedAt: queuedAt,
        blockedReason: reason,
      );

  /// Malformed or hand-edited entries are dropped, never trusted.
  static PendingMove? fromJson(Object? value) {
    if (value is! Map) return null;
    final entryId = value['entryId'];
    final fileId = value['fileId'];
    final nameEnc = value['sourceNameEnc'];
    final sourceParent = value['sourceParentId'];
    final destination = value['destinationParentId'];
    final queuedAt = DateTime.tryParse(value['queuedAt'] as String? ?? '');
    final blockedReason = value['blockedReason'];
    if (entryId is! String || entryId.isEmpty) return null;
    if (fileId is! String || fileId.isEmpty) return null;
    if (nameEnc is! String || nameEnc.isEmpty) return null;
    if (sourceParent != null && sourceParent is! String) return null;
    if (destination != null && destination is! String) return null;
    if (queuedAt == null) return null;
    if (blockedReason != null && blockedReason is! String) return null;
    return PendingMove(
      entryId: entryId,
      fileId: fileId,
      sourceParentId: sourceParent as String?,
      sourceNameEnc: nameEnc,
      destinationParentId: destination as String?,
      isDir: value['isDir'] == true,
      queuedAt: queuedAt,
      blockedReason: blockedReason as String?,
    );
  }
}

/// Storage seam: production uses local preferences, tests use memory.
abstract class PendingMoveStore {
  Future<List<PendingMove>> load();
  Future<void> save(List<PendingMove> moves);
}

class PreferencesPendingMoveStore implements PendingMoveStore {
  const PreferencesPendingMoveStore();

  static const prefsKey = 'pendingMoves';

  @override
  Future<List<PendingMove>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final moves = <PendingMove>[];
      for (final entry in decoded) {
        final move = PendingMove.fromJson(entry);
        if (move != null) moves.add(move);
      }
      return moves.take(pendingMoveLimit).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<PendingMove> moves) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        prefsKey, jsonEncode([for (final move in moves) move.toJson()]));
  }
}

enum PendingMoveAdd { added, duplicate, full }

/// Reads and writes queued moves. One entry per item: a second offline move of
/// the same item is refused rather than applied twice later.
class PendingMoveQueue {
  PendingMoveQueue({required this.store, this.limit = pendingMoveLimit}) {
    if (limit < 1 || limit > pendingMoveLimit) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..$pendingMoveLimit');
    }
  }

  final PendingMoveStore store;
  final int limit;

  Future<List<PendingMove>> load() => store.load();

  Future<PendingMoveAdd> enqueue({
    required RemoteFile file,
    required String? destinationParentId,
    DateTime? now,
    String? entryId,
  }) async {
    final moves = await store.load();
    if (moves.any((move) => move.fileId == file.id)) {
      return PendingMoveAdd.duplicate;
    }
    if (moves.length >= limit) return PendingMoveAdd.full;
    await store.save([
      ...moves,
      PendingMove(
        entryId: entryId ?? const Uuid().v4(),
        fileId: file.id,
        sourceParentId: file.parentId,
        sourceNameEnc: file.nameEnc,
        destinationParentId: destinationParentId,
        isDir: file.isDir,
        queuedAt: (now ?? DateTime.now()).toUtc(),
      ),
    ]);
    return PendingMoveAdd.added;
  }

  /// Drop every queued move that stopped retrying.
  Future<void> discardBlocked() async {
    final moves = await store.load();
    await store.save([
      for (final move in moves)
        if (move.blockedReason == null) move
    ]);
  }
}

/// Outcome of one replay pass. Messages are plain language and never contain a
/// filename, path or server diagnostic.
class PendingMoveFlush {
  const PendingMoveFlush({
    this.applied = 0,
    this.offline = false,
    this.locked = false,
    this.pending = 0,
    this.needsAttention = 0,
    this.problems = const [],
  });

  final int applied;

  /// The server was unreachable; remaining entries stay queued.
  final bool offline;

  /// The session is locked or closing; remaining entries stay queued.
  final bool locked;
  final int pending;
  final int needsAttention;
  final List<String> problems;
}

/// Replays queued moves. A seam for tests; production always uses
/// [flushPendingMoves].
typedef PendingMoveFlusher = Future<PendingMoveFlush> Function({
  required ApiClient api,
  required int handle,
  required PendingMoveQueue queue,
});

/// Apply queued moves in order. Stops at the first connectivity or session
/// failure so the queue keeps its order, and keeps a conflicting entry so
/// nothing is silently dropped or overwritten.
Future<PendingMoveFlush> flushPendingMoves({
  required ApiClient api,
  required int handle,
  required PendingMoveQueue queue,
}) async {
  final moves = await queue.load();
  if (moves.isEmpty) return const PendingMoveFlush();

  var applied = 0;
  var offline = false;
  var locked = false;
  final problems = <String>[];
  final remaining = <PendingMove>[];

  for (var index = 0; index < moves.length; index++) {
    final move = moves[index];
    if (move.blockedReason != null) {
      remaining.add(move);
      continue;
    }
    try {
      final destination =
          await api.listFiles(parentId: move.destinationParentId);
      if (destination.length > pendingMoveListingLimit) {
        throw RenameFailure(
            'The destination folder is too large for a safe move.');
      }
      // An earlier attempt whose reply was lost may already have applied this
      // move. The item is then already in the destination, and nothing remains
      // to do.
      if (destination.any((entry) => entry.id == move.fileId)) {
        applied++;
        continue;
      }
      await moveRemoteEntry(
        api: api,
        handle: handle,
        file: RemoteFile(move.fileId, move.sourceParentId, move.sourceNameEnc,
            move.isDir, 0, false, 0, null),
        parentId: move.destinationParentId,
      );
      applied++;
    } on RenameFailure catch (e) {
      // A destination collision or a source changed elsewhere: keep the entry,
      // report it, and stop retrying this one automatically.
      remaining.add(move.blocked(e.message));
      problems.add(e.message);
    } on ApiException catch (e) {
      if (e.status == 0) {
        offline = true;
        remaining.add(move);
        remaining.addAll(moves.sublist(index + 1));
        break;
      }
      if (e.status == 401 || e.status == 403) {
        locked = true;
        remaining.add(move);
        remaining.addAll(moves.sublist(index + 1));
        break;
      }
      if (e.status == 404) {
        problems.add(
            'A queued move was dropped because its item no longer exists.');
        continue;
      }
      remaining.add(move.blocked('The server refused this queued move.'));
      problems.add(
          'A queued move was refused by the server and will not be retried.');
    } on NativeException {
      locked = true;
      remaining.add(move);
      remaining.addAll(moves.sublist(index + 1));
      break;
    }
  }

  await queue.store.save(remaining);
  return PendingMoveFlush(
    applied: applied,
    offline: offline,
    locked: locked,
    pending: remaining.length,
    needsAttention:
        remaining.where((move) => move.blockedReason != null).length,
    problems: problems,
  );
}
