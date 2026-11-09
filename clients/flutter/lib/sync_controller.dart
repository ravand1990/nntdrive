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

import 'api.dart';
import 'native.dart';
import 'session_operations.dart';
import 'storage_access.dart';

typedef SyncRunner = Future<Map<String, dynamic>> Function(
    int handle,
    Map<String, dynamic> request,
    void Function(Map<String, dynamic>) onProgress);

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
  });

  final String server;
  final String token;
  final int handle;
  final ApiClient api;
  final StorageAccess storageAccess;
  final SyncRunner syncRunner;

  final List<SyncFolderConfig> folders = [];
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

  static const _prefsKey = 'syncFolders';
  static const _pausedKey = 'syncPaused';
  static const autoSyncInterval = Duration(minutes: 5);

  Future<void> load() => _stopped ? Future.value() : _operations.run(0, _load);

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    paused = prefs.getBool(_pausedKey) ?? false;
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
    await scanConflicts();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(folders.map((f) => f.toJson()).toList()));
    await prefs.setBool(_pausedKey, paused);
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
    try {
      final sealed = NativeBridge.instance.sealName(handle, remoteRootId, name);
      await api.createFile(
        id: remoteRootId,
        parentId: null,
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
    } else {
      lastStatus = 'Folder added and synchronized.';
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
    if (folders.isEmpty) {
      if (!silent) {
        lastStatus = 'Add a folder to start syncing.';
        notifyListeners();
      }
      return;
    }
    syncing = true;
    lastStatus = 'Syncing…';
    notifyListeners();
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
    lastStatus = failures > 0
        ? '$failures folder(s) had errors; $uploaded uploaded, $downloaded downloaded, $conflicts conflict(s).'
        : 'Sync complete: $uploaded uploaded, $downloaded downloaded, $conflicts conflict(s).';
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
