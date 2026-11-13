// Multi-folder synchronization controller for the desktop/mobile UI.
//
// Encryption and reconciliation happen in the Rust core. This class only keeps
// the local folder list, journals and auto-sync timer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'account_roots.dart';
import 'api.dart';
import 'native.dart';
import 'pending_moves.dart';
import 'session_operations.dart';
import 'space_migration.dart';
import 'space_subscription.dart';
import 'storage_access.dart';

typedef SyncRunner = Future<Map<String, dynamic>> Function(
    int handle,
    Map<String, dynamic> request,
    void Function(Map<String, dynamic>) onProgress);

/// Bootstraps and lists the fixed account roots. Injected for tests.
typedef AccountRootsLoader = Future<AccountRootsResult> Function();

Future<Map<String, dynamic>> _runNativeSync(
        int handle,
        Map<String, dynamic> request,
        void Function(Map<String, dynamic>) progress) =>
    NativeBridge.instance
        .syncRequestAsync(handle, request, onProgress: progress);

class SyncFolderConfig {
  SyncFolderConfig({
    required this.id,
    required this.name,
    required this.localPath,
    required this.remoteRootId,
    this.enabled = true,
    this.lastSync,
    this.lastError,
    this.lastReport,
    List<String>? excluded,
  }) : excluded = excluded ?? [];

  final String id;
  String name;
  String localPath;
  final String remoteRootId;
  bool enabled;
  String? lastSync;
  String? lastError;
  Map<String, dynamic>? lastReport;

  /// Relative local paths excluded from synchronization.
  List<String> excluded;

  /// Discovered conflict copies under this root (computed, not persisted).
  List<String> conflictFiles = [];
  Map<String, dynamic>? progress;
  bool running = false;
  bool storageAccessRequired = false;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'localPath': localPath,
        'remoteRootId': remoteRootId,
        'enabled': enabled,
        'lastSync': lastSync,
        'lastError': lastError,
        'lastReport': lastReport,
        'excluded': excluded,
      };

  static SyncFolderConfig fromJson(Map<String, dynamic> j) => SyncFolderConfig(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Folder',
        localPath: j['localPath'] as String,
        remoteRootId: j['remoteRootId'] as String,
        enabled: j['enabled'] as bool? ?? true,
        lastSync: j['lastSync'] as String?,
        lastError: j['lastError'] as String?,
        lastReport: j['lastReport'] as Map<String, dynamic>?,
        excluded: (j['excluded'] as List?)?.map((e) => e.toString()).toList(),
      );

  int get uploaded => (lastReport?['uploaded'] as int?) ?? 0;
  int get downloaded => (lastReport?['downloaded'] as int?) ?? 0;
  int get conflicts => (lastReport?['conflicts'] as int?) ?? 0;
  bool get hasErrors =>
      (lastError?.isNotEmpty ?? false) ||
      (lastReport?['errors'] as List?)?.isNotEmpty == true;
}

class SyncController extends ChangeNotifier {
  SyncController({
    required this.server,
    required this.token,
    required this.handle,
    required this.api,
    this.storageAccess = const StorageAccess(),
    this.syncRunner = _runNativeSync,
    PendingMoveQueue? pendingMoves,
    this.pendingMoveFlusher = flushPendingMoves,
    RootNameSealer? nameSealer,
    AccountRootsLoader? rootsLoader,
  })  : pendingMoves = pendingMoves ??
            PendingMoveQueue(store: const PreferencesPendingMoveStore()),
        nameSealer = nameSealer ??
            ((nodeId, name) =>
                NativeBridge.instance.sealName(handle, nodeId, name)),
        rootsLoader = rootsLoader ??
            (() => AccountRootsService(
                  api: api,
                  sealName: (nodeId, name) =>
                      NativeBridge.instance.sealName(handle, nodeId, name),
                ).ensure());

  final String server;
  final String token;
  final int handle;
  final ApiClient api;
  final StorageAccess storageAccess;
  final SyncRunner syncRunner;
  final RootNameSealer nameSealer;
  final AccountRootsLoader rootsLoader;

  /// Moves saved on this device while the server was unreachable.
  final PendingMoveQueue pendingMoves;
  final PendingMoveFlusher pendingMoveFlusher;

  final List<SyncFolderConfig> folders = [];

  /// Fixed account roots: Global first, then every device space.
  final List<AccountRoot> accountRoots = [];

  /// This device's own fixed space, when the account has one. New sync folders
  /// are created inside it, so two devices never place a folder at the same
  /// account-root path.
  String? deviceRootNodeId;
  String? rootsWarning;
  String? rootsError;
  bool rootsLoading = false;

  /// Sync folders whose remote folder still sits at the account root because it
  /// was created before account spaces existed. Advisory: these are ordinary
  /// synced folders, listed so they can be moved into this device's space.
  List<RemoteFile> legacySpaceFolders = const [];
  bool paused = false;
  bool syncing = false;
  String? lastStatus;
  Timer? _timer;
  Timer? _initialTimer;
  bool _stopped = false;
  bool _disposed = false;
  final _operations = SessionOperations();
  bool _started = false;
  bool _loaded = false;
  bool get loaded => _loaded;
  final Set<String> _running = {};

  /// Offline moves waiting on this device, and how many stopped retrying.
  int pendingMoveCount = 0;
  int pendingMoveAttention = 0;

  static const _prefsKey = 'syncFolders';
  static const _pausedKey = 'syncPaused';
  static const _spaceOptOutKey = 'spacesNotAutoSynced';

  /// Spaces the user stopped syncing on this device. Global stays opted out
  /// until it is subscribed again, so a restart cannot silently re-mirror it.
  final Set<String> _spaceOptOut = {};
  static const autoSyncInterval = Duration(minutes: 5);

  Future<void> load() => _stopped ? Future.value() : _operations.run(0, _load);

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    paused = prefs.getBool(_pausedKey) ?? false;
    _spaceOptOut
      ..clear()
      ..addAll(prefs.getStringList(_spaceOptOutKey) ?? const []);
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        folders
          ..clear()
          ..addAll(list.map(
              (e) => SyncFolderConfig.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        folders.clear();
      }
    }
    notifyListeners();
    await _refreshPendingMoveCounts();
    await _refreshAccountRoots();
    // A reconnect attempt is best-effort: an offline launch keeps the queue as
    // it was, and unlock or folder sync must never fail because of it.
    await _applyPendingMoves(silent: true);
    await scanConflicts();
    _loaded = true;
    notifyListeners();
  }

  /// Re-read (and, on first unlock, bootstrap) the fixed account spaces.
  ///
  /// Failures stay in [rootsError] and never block folder sync: the spaces are
  /// an addition to the existing per-folder setup.
  Future<void> refreshAccountRoots() {
    if (_stopped) return Future.value();
    return _operations.run(0, _refreshAccountRoots);
  }

  Future<void> _refreshAccountRoots() async {
    rootsLoading = true;
    rootsError = null;
    notifyListeners();
    try {
      final result = await rootsLoader();
      if (_stopped) return;
      accountRoots
        ..clear()
        ..addAll(result.roots);
      deviceRootNodeId = result.deviceRootNodeId;
      rootsWarning = result.warning;
      try {
        await _autoSubscribeGlobal();
      } catch (_) {
        // A subscription problem must not hide the space list.
      }
      await _refreshLegacyFolders();
    } catch (e) {
      rootsError = _rootsErrorText(e);
    } finally {
      rootsLoading = false;
      if (!_stopped) notifyListeners();
    }
  }

  String _rootsErrorText(Object e) {
    if (e is ApiException) {
      if (e.status == 0) {
        return 'Could not reach the server to set up account spaces.';
      }
      if (e.status == 401 || e.status == 403) {
        return 'Sign in again to set up account spaces.';
      }
      return 'Could not set up account spaces. Retry when the server is reachable.';
    }
    if (e is NativeException) {
      return 'Unlock the app, then set up account spaces.';
    }
    return 'Could not set up account spaces. Retry.';
  }

  /// Re-detect synced folders whose remote folder still sits at the account
  /// root. Read-only and advisory: a listing failure clears the notice rather
  /// than listing folders that may already have been moved.
  Future<void> refreshLegacyFolders() {
    if (_stopped) return Future.value();
    return _operations.run(0, _refreshLegacyFolders);
  }

  Future<void> _refreshLegacyFolders() async {
    if (accountRoots.isEmpty || folders.isEmpty) {
      legacySpaceFolders = const [];
      return;
    }
    try {
      final topLevel = await api.listFiles();
      if (_stopped) return;
      legacySpaceFolders = foldersOutsideSpaces(
        accountTopLevel: topLevel,
        roots: accountRoots,
        syncRootIds: folders.map((folder) => folder.remoteRootId),
      );
    } catch (_) {
      legacySpaceFolders = const [];
    }
    if (!_stopped) notifyListeners();
  }

  /// Move one pre-spaces sync folder into this device's space.
  ///
  /// The guarded move keeps the node, its sealed name, every version and its
  /// subtree, and the local sync entry keeps working because it tracks the
  /// remote root node ID rather than a path. Returns user-facing text; an
  /// expected failure changes nothing.
  Future<String> moveLegacyFolderIntoDeviceSpace(RemoteFile folder) {
    if (_stopped) {
      return Future.value('The app is closing. Try this again after reopening it.');
    }
    return _operations.run(0, () async {
      final message = await moveFolderIntoDeviceSpace(
        api: api,
        handle: handle,
        folder: folder,
        roots: accountRoots,
        deviceRootNodeId: deviceRootNodeId,
      );
      await _refreshLegacyFolders();
      if (!_stopped) {
        lastStatus = message;
        notifyListeners();
      }
      return message;
    });
  }

  /// Queue a move that could not reach the server. The returned message is
  /// shown to the user and never contains a filename or path.
  Future<String> enqueueOfflineMove(
      RemoteFile file, String? destinationParentId) {
    if (_stopped) {
      return Future.value(
          'The app is closing. Try this move again after reopening it.');
    }
    return _operations.run(0, () async {
      final result = await pendingMoves.enqueue(
          file: file, destinationParentId: destinationParentId);
      await _refreshPendingMoveCounts();
      switch (result) {
        case PendingMoveAdd.added:
          return 'You are offline. This move is saved on this device and will be applied when the server can be reached.';
        case PendingMoveAdd.duplicate:
          return 'You are offline. A move for this item is already waiting to be applied.';
        case PendingMoveAdd.full:
          return 'You are offline and too many moves are already waiting. Reconnect and apply them first.';
      }
    });
  }

  /// Re-read the queued moves from local storage.
  Future<void> refreshPendingMoves() {
    if (_stopped) return Future.value();
    return _operations.run(0, () async {
      await _refreshPendingMoveCounts();
    });
  }

  /// Try every queued move now, for example on an explicit "Apply now".
  Future<void> applyPendingMoves() {
    if (_stopped) return Future.value();
    return _operations.run(0, () async {
      await _applyPendingMoves();
    });
  }

  /// Drop queued moves that stopped retrying after a conflict.
  Future<void> discardPendingMoves() {
    if (_stopped) return Future.value();
    return _operations.run(0, () async {
      await pendingMoves.discardBlocked();
      await _refreshPendingMoveCounts();
      if (pendingMoveAttention == 0) {
        lastStatus = 'Queued moves that needed attention were discarded.';
      }
      notifyListeners();
    });
  }

  Future<void> _refreshPendingMoveCounts() async {
    try {
      final moves = await pendingMoves.load();
      pendingMoveCount = moves.length;
      pendingMoveAttention = moves.where((m) => m.blockedReason != null).length;
    } catch (_) {
      pendingMoveCount = 0;
      pendingMoveAttention = 0;
    }
    notifyListeners();
  }

  /// Apply queued moves. Never throws: a queued move is a convenience and must
  /// not break unlock, sync or the rest of the queue.
  Future<PendingMoveFlush> _applyPendingMoves({bool silent = false}) async {
    PendingMoveFlush flush;
    try {
      flush = await pendingMoveFlusher(
          api: api, handle: handle, queue: pendingMoves);
    } catch (_) {
      await _refreshPendingMoveCounts();
      return const PendingMoveFlush();
    }
    pendingMoveCount = flush.pending;
    pendingMoveAttention = flush.needsAttention;
    if (flush.applied > 0) {
      lastStatus = 'Applied ${flush.applied} queued move(s).';
    } else if (!silent && flush.needsAttention > 0) {
      lastStatus =
          'A queued move needs attention: the item or its destination changed elsewhere.';
    } else if (!silent && flush.problems.isNotEmpty) {
      lastStatus = flush.problems.first;
    }
    notifyListeners();
    return flush;
  }

  /// The sync entry that already mirrors [nodeId] on this device, if any.
  SyncFolderConfig? folderForSpace(String nodeId) {
    for (final folder in folders) {
      if (folder.remoteRootId == nodeId) return folder;
    }
    return null;
  }

  bool spaceSubscribed(AccountRoot root) => folderForSpace(root.nodeId) != null;

  /// Mirror an account space on this device: create its local folder, record a
  /// sync entry bound to the space node and run the existing sync engine.
  Future<bool> subscribeSpace(AccountRoot root) {
    if (_stopped) return Future.value(false);
    return _operations.run(0, () => _subscribeSpace(root));
  }

  /// Stop mirroring an account space here. The remote space, its files and the
  /// local journal are kept, so subscribing again does not re-download the tree.
  Future<void> unsubscribeSpace(AccountRoot root) {
    if (_stopped) return Future.value();
    return _operations.run(0, () async {
      final folder = folderForSpace(root.nodeId);
      if (folder != null && (folder.running || syncing)) {
        throw StateError('Wait for sync to finish');
      }
      _spaceOptOut.add(root.nodeId);
      await _save();
      if (folder != null) {
        await _removeFolder(folder, deleteJournal: false);
      }
      lastStatus =
          '${accountRootLabel(root)} is no longer synchronized on this device.';
      notifyListeners();
    });
  }

  /// Every client mirrors Global without the user adding a folder. A user who
  /// stopped it stays opted out; nothing is created when roots are unavailable.
  Future<void> _autoSubscribeGlobal() async {
    if (_stopped) return;
    AccountRoot? global;
    for (final root in accountRoots) {
      if (root.isGlobal) {
        global = root;
        break;
      }
    }
    if (global == null) return;
    if (folderForSpace(global.nodeId) != null) return;
    if (_spaceOptOut.contains(global.nodeId)) return;
    await _subscribeSpace(global);
  }

  Future<bool> _subscribeSpace(AccountRoot root) async {
    if (_stopped) return false;
    if (folderForSpace(root.nodeId) != null) return true;
    final label = accountRootLabel(root);
    final Directory spaces;
    try {
      final documents = await getApplicationDocumentsDirectory();
      spaces = Directory(p.join(documents.path, spacesDirectoryName));
      if (!spaces.existsSync()) spaces.createSync(recursive: true);
    } catch (_) {
      lastStatus =
          'Could not create the local folder for $label on this device.';
      notifyListeners();
      return false;
    }
    final name = uniqueSpaceFolderName(
        label, folders.map((folder) => p.basename(folder.localPath)));
    String? path;
    if (name != null) {
      try {
        path = spaceDirectoryPath(spaces.path, name);
      } on ArgumentError {
        path = null;
      }
    }
    if (path == null) {
      lastStatus = 'Could not name a local folder for $label.';
      notifyListeners();
      return false;
    }
    try {
      await Directory(path).create(recursive: true);
    } catch (_) {
      lastStatus =
          'Could not create the local folder for $label on this device.';
      notifyListeners();
      return false;
    }
    final config = SyncFolderConfig(
      id: const Uuid().v4(),
      name: label,
      localPath: path,
      remoteRootId: root.nodeId,
    );
    folders.add(config);
    _spaceOptOut.remove(root.nodeId);
    await _save();
    final report = await syncFolder(config, silent: true);
    if (_stopped) return true;
    if (paused) {
      lastStatus = 'Subscribed $label. Sync is paused.';
    } else if (report == null) {
      lastStatus = 'Subscribed $label. Select Sync all to start it.';
    } else if (config.hasErrors) {
      lastStatus = 'Subscribed $label, but sync needs attention.';
    } else {
      lastStatus = 'Subscribed $label and synchronized it.';
    }
    notifyListeners();
    return true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(folders.map((f) => f.toJson()).toList()));
    await prefs.setBool(_pausedKey, paused);
    await prefs.setStringList(_spaceOptOutKey, _spaceOptOut.toList());
    notifyListeners();
  }

  void start() {
    if (_started || _stopped) return;
    _started = true;
    _timer = Timer.periodic(autoSyncInterval, (_) {
      if (!paused) syncAll(silent: true);
    });
    // Give the app a moment to finish loading, then do an initial pass.
    _initialTimer = Timer(const Duration(seconds: 2), () {
      if (!paused) syncAll(silent: true);
    });
  }

  Future<bool> addFolder(String localPath) {
    if (_stopped) return Future.value(false);
    return _operations.run(0, () => _addFolder(localPath));
  }

  Future<bool> _addFolder(String localPath) async {
    final path = p.normalize(localPath);
    final overlaps = folders.any((f) =>
        p.equals(f.localPath, path) ||
        p.isWithin(f.localPath, path) ||
        p.isWithin(path, f.localPath));
    if (overlaps) {
      lastStatus =
          'That folder overlaps an existing sync folder. Choose a separate tree.';
      notifyListeners();
      return false;
    }
    try {
      await storageAccess.check(path);
    } catch (e) {
      lastStatus = e is StorageAccessException
          ? e.toString()
          : 'Could not check local storage access. Retry this folder.';
      notifyListeners();
      return false;
    }
    final id = const Uuid().v4();
    final remoteRootId = const Uuid().v4();
    final name = p.basename(path).isEmpty ? 'Sync folder' : p.basename(path);
    // Place the remote folder inside this device's fixed space. Two devices
    // adding the same local name then get separate parents instead of one
    // account-root path; without a device space fall back to the account root.
    final parentId = deviceRootNodeId;
    try {
      final sealed = nameSealer(remoteRootId, name);
      await api.createFile(
        id: remoteRootId,
        parentId: parentId,
        nameEnc: sealed,
        isDir: true,
      );
    } catch (e) {
      lastStatus = 'Could not create the remote folder: $e';
      notifyListeners();
      return false;
    }
    final config = SyncFolderConfig(
      id: id,
      name: name,
      localPath: path,
      remoteRootId: remoteRootId,
    );
    folders.add(config);
    await _save();
    final report = await syncFolder(config, silent: true);
    if (report == null || config.hasErrors) {
      lastStatus =
          'Folder added, but sync needs attention. Check its error and retry.';
    } else if (parentId == null) {
      lastStatus = 'Folder added and synchronized.';
    } else {
      lastStatus = 'Folder added inside this device space and synchronized.';
    }
    notifyListeners();
    return true;
  }

  Future<void> removeFolder(SyncFolderConfig folder,
      {bool deleteJournal = true}) {
    if (_stopped) return Future.value();
    if (folder.running || syncing) {
      return Future.error(StateError('Wait for sync to finish'));
    }
    return _operations.run(
        0, () => _removeFolder(folder, deleteJournal: deleteJournal));
  }

  Future<void> _removeFolder(SyncFolderConfig folder,
      {bool deleteJournal = true}) async {
    folders.removeWhere((f) => f.id == folder.id);
    if (deleteJournal) {
      try {
        final support = await getApplicationSupportDirectory();
        final base = p.join(support.path, 'sync', '${folder.id}.sqlite');
        for (final suffix in ['', '.remote-hashes.json']) {
          final file = File('$base$suffix');
          if (file.existsSync()) file.deleteSync();
        }
      } catch (_) {}
    }
    await _save();
  }

  /// Read-only equality evidence for one freshly listed remote file.
  Future<bool> fileMatches(
      SyncFolderConfig folder, String relative, RemoteFile entry) {
    if (_stopped) return Future.value(false);
    return _operations.run(0, () => _fileMatches(folder, relative, entry));
  }

  Future<bool> _fileMatches(
      SyncFolderConfig folder, String relative, RemoteFile entry) async {
    if (folder.running || entry.isDir || entry.currentVersion == null) {
      return false;
    }
    final support = await getApplicationSupportDirectory();
    if (folder.running) return false;
    final matches = await NativeBridge.instance.localFileMatches({
      'handle': handle,
      'journalPath': p.join(support.path, 'sync', '${folder.id}.sqlite'),
      'localPath': p.normalize(p.absolute(folder.localPath)),
      'relativePath': relative,
      'revision': entry.currentVersion,
      'size': entry.size,
    });
    return !folder.running && matches;
  }

  Future<void> setEnabled(SyncFolderConfig folder, bool enabled) {
    if (_stopped) return Future.value();
    return _operations.run(0, () => _setEnabled(folder, enabled));
  }

  Future<void> _setEnabled(SyncFolderConfig folder, bool enabled) async {
    folder.enabled = enabled;
    await _save();
    if (enabled) await syncFolder(folder);
  }

  Future<void> setExcluded(SyncFolderConfig folder, List<String> excluded) {
    if (_stopped) return Future.value();
    return _operations.run(0, () => _setExcluded(folder, excluded));
  }

  Future<void> _setExcluded(
      SyncFolderConfig folder, List<String> excluded) async {
    folder.excluded = excluded
        .map((e) =>
            e.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), ''))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    await _save();
    await syncFolder(folder);
  }

  /// Finds conflict copies created by the sync engine inside selected folders.
  Future<void> scanConflicts() async {
    for (final folder in folders) {
      folder.conflictFiles.clear();
      if (!Directory(folder.localPath).existsSync()) continue;
      try {
        await for (final entity in Directory(folder.localPath)
            .list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          if (!p.basename(entity.path).contains(' (conflict ')) continue;
          final rel = p
              .relative(entity.path, from: folder.localPath)
              .replaceAll('\\', '/');
          if (folder.excluded
              .any((ex) => rel == ex || rel.startsWith('$ex/'))) {
            continue;
          }
          folder.conflictFiles.add(rel);
          if (folder.conflictFiles.length >= 500) break;
        }
      } catch (_) {
        // Unreadable folders are reported by sync itself.
      }
    }
    notifyListeners();
  }

  int get conflictCount =>
      folders.fold(0, (sum, folder) => sum + folder.conflictFiles.length);

  Future<void> setPaused(bool value) {
    if (_stopped) return Future.value();
    return _operations.run(0, () async {
      paused = value;
      await _save();
    });
  }

  Future<void> syncAll({bool silent = false}) => _stopped
      ? Future.value()
      : _operations.run(0, () => _syncAll(silent: silent));

  Future<void> _syncAll({bool silent = false}) async {
    if (syncing || paused) return;
    final queuedMoves = await _applyPendingMoves(silent: silent);
    if (folders.isEmpty) {
      if (!silent && queuedMoves.applied == 0) {
        lastStatus = 'Add a folder to start syncing.';
        notifyListeners();
      }
      return;
    }
    syncing = true;
    lastStatus = 'Syncing…';
    notifyListeners();
    if (queuedMoves.applied > 0) {
      lastStatus = 'Applied ${queuedMoves.applied} queued move(s). Syncing…';
    }
    var uploaded = 0;
    var downloaded = 0;
    var conflicts = 0;
    var failures = 0;
    for (final folder in folders.where((f) => f.enabled).toList()) {
      final report = await syncFolder(folder, silent: true);
      if (report == null) {
        failures++;
      } else {
        uploaded += (report['uploaded'] as int?) ?? 0;
        downloaded += (report['downloaded'] as int?) ?? 0;
        conflicts += (report['conflicts'] as int?) ?? 0;
        if ((report['errors'] as List?)?.isNotEmpty == true) failures++;
      }
    }
    syncing = false;
    final moveNote = queuedMoves.applied > 0
        ? 'Applied ${queuedMoves.applied} queued move(s). '
        : '';
    lastStatus = failures > 0
        ? '$moveNote$failures folder(s) had errors; $uploaded uploaded, $downloaded downloaded, $conflicts conflict(s).'
        : '${moveNote}Sync complete: $uploaded uploaded, $downloaded downloaded, $conflicts conflict(s).';
    await _save();
  }

  Future<Map<String, dynamic>?> syncFolder(SyncFolderConfig folder,
          {bool silent = false}) =>
      _stopped
          ? Future.value(null)
          : _operations.run(0, () => _syncFolder(folder, silent: silent));

  Future<Map<String, dynamic>?> _syncFolder(SyncFolderConfig folder,
      {bool silent = false}) async {
    if (paused ||
        !folder.enabled ||
        !folders.contains(folder) ||
        _running.contains(folder.id)) {
      return null;
    }
    _running.add(folder.id);
    folder.running = true;
    folder.progress = null;
    notifyListeners();
    if (!silent) {
      lastStatus = 'Syncing ${folder.name}…';
      notifyListeners();
    }
    try {
      await storageAccess.check(folder.localPath);
      folder.storageAccessRequired = false;
      final support = await getApplicationSupportDirectory();
      final syncDir = Directory(p.join(support.path, 'sync'));
      if (!syncDir.existsSync()) syncDir.createSync(recursive: true);
      final journal = p.join(syncDir.path, '${folder.id}.sqlite');
      final report = await syncRunner(handle, {
        'baseUrl': server,
        'token': token,
        'remoteRootId': folder.remoteRootId,
        'localPath': folder.localPath,
        'journalPath': journal,
        'deviceName': Platform.localHostname,
        'excluded': folder.excluded,
      }, (event) {
        folder.progress = event;
        notifyListeners();
      });
      folder.lastReport = report;
      folder.lastSync = DateTime.now().toIso8601String();
      final errors = report['errors'];
      folder.lastError = (errors is List && errors.isNotEmpty)
          ? errors.map((e) => e.toString()).join('\n')
          : null;
      if (!silent) {
        lastStatus = '${folder.name}: ${report['uploaded']} uploaded, '
            '${report['downloaded']} downloaded, ${report['conflicts']} conflict(s).';
      }
      return report;
    } catch (e) {
      folder.storageAccessRequired =
          e is StorageAccessException && e.permissionRequired;
      folder.lastError = e is StorageAccessException
          ? e.toString()
          : 'Sync failed. Check storage access and server connectivity, then retry.';
      if (!silent) lastStatus = '${folder.name}: ${folder.lastError}';
      return null;
    } finally {
      _running.remove(folder.id);
      folder.running = false;
      folder.progress = null;
      await _save();
      await scanConflicts();
    }
  }

  /// An explicit UI attempt; no scheduler can broaden storage permissions.
  Future<bool> grantStorageAccess(SyncFolderConfig folder) {
    if (_stopped) return Future.value(false);
    return _operations.run(0, () async {
      final granted = await storageAccess.request();
      if (!granted || _stopped || !folders.contains(folder)) return false;
      final report = await syncFolder(folder);
      return report != null && !folder.hasErrors;
    });
  }

  /// Permanent session stop, not the persisted user pause preference.
  Future<void> stopAndDrain() {
    _stopped = true;
    _timer?.cancel();
    _initialTimer?.cancel();
    return _operations.drain(0);
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    stopAndDrain();
    _disposed = true;
    super.dispose();
  }

  Future<void> resolveConflict(
      SyncFolderConfig folder, String copy, String choice) {
    if (_stopped) return Future.error(StateError('Session is closing'));
    return _operations.run(0, () => _resolveConflict(folder, copy, choice));
  }

  Future<void> _resolveConflict(
      SyncFolderConfig folder, String copy, String choice) async {
    if (_running.contains(folder.id) || syncing) {
      throw StateError('Wait for sync to finish');
    }
    final original = originalConflictPath(copy);
    if (original == null) throw StateError('Cannot identify the original file');
    _running.add(folder.id);
    folder.running = true;
    notifyListeners();
    try {
      await storageAccess.check(folder.localPath);
      final support = await getApplicationSupportDirectory();
      await syncRunner(handle, {
        'baseUrl': server,
        'token': token,
        'remoteRootId': folder.remoteRootId,
        'localPath': folder.localPath,
        'journalPath': p.join(support.path, 'sync', '${folder.id}.sqlite'),
        'deviceName': Platform.localHostname,
        'excluded': folder.excluded,
        'original': original,
        'copy': copy,
        'choice': choice,
      }, (event) {
        folder.progress = event;
        notifyListeners();
      });
      folder.lastError = null;
      lastStatus =
          'Conflict resolved; both versions remain recoverable in synced files.';
    } catch (e) {
      folder.lastError = e.toString();
      rethrow;
    } finally {
      _running.remove(folder.id);
      folder.running = false;
      folder.progress = null;
      await _save();
      await scanConflicts();
    }
  }
}

/// Only propose a pair; the dialog shows both paths and the core revalidates
/// local hashes and remote revisions before applying a choice.
String? originalConflictPath(String copy) {
  final marker = copy.lastIndexOf(' (conflict ');
  if (marker < 0) return null;
  final end = copy.indexOf(')', marker);
  return end < 0 ? null : copy.substring(0, marker) + copy.substring(end + 1);
}
