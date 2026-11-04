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
  bool get hasErrors => (lastError?.isNotEmpty ?? false) || (lastReport?['errors'] as List?)?.isNotEmpty == true;
}

class SyncController extends ChangeNotifier {
  SyncController({
    required this.server,
    required this.token,
    required this.handle,
    required this.api,
  });

  final String server;
  final String token;
  final int handle;
  final ApiClient api;

  final List<SyncFolderConfig> folders = [];
  bool paused = false;
  bool syncing = false;
  String? lastStatus;
  Timer? _timer;
  bool _started = false;
  final Set<String> _running = {};

  static const _prefsKey = 'syncFolders';
  static const _pausedKey = 'syncPaused';
  static const autoSyncInterval = Duration(minutes: 5);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    paused = prefs.getBool(_pausedKey) ?? false;
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        folders
          ..clear()
          ..addAll(list.map((e) => SyncFolderConfig.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        folders.clear();
      }
    }
    notifyListeners();
    await scanConflicts();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(folders.map((f) => f.toJson()).toList()));
    await prefs.setBool(_pausedKey, paused);
    notifyListeners();
  }

  void start() {
    if (_started) return;
    _started = true;
    _timer = Timer.periodic(autoSyncInterval, (_) {
      if (!paused) syncAll(silent: true);
    });
    // Give the app a moment to finish loading, then do an initial pass.
    Timer(const Duration(seconds: 2), () {
      if (!paused) syncAll(silent: true);
    });
  }

  Future<bool> addFolder(String localPath) async {
    final path = p.normalize(localPath);
    final overlaps = folders.any((f) =>
        p.equals(f.localPath, path) ||
        p.isWithin(f.localPath, path) ||
        p.isWithin(path, f.localPath));
    if (overlaps) {
      lastStatus = 'That folder overlaps an existing sync folder. Choose a separate tree.';
      notifyListeners();
      return false;
    }
    if (!Directory(path).existsSync()) {
      lastStatus = 'Folder does not exist: $path';
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
    await syncFolder(config, silent: true);
    return true;
  }

  Future<void> removeFolder(SyncFolderConfig folder, {bool deleteJournal = true}) async {
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

  Future<void> setEnabled(SyncFolderConfig folder, bool enabled) async {
    folder.enabled = enabled;
    await _save();
    if (enabled) await syncFolder(folder);
  }

  Future<void> setExcluded(SyncFolderConfig folder, List<String> excluded) async {
    folder.excluded = excluded
        .map((e) => e.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), ''))
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
          if (folder.excluded.any((ex) =>
              rel == ex || rel.startsWith('$ex/'))) {
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

  Future<void> setPaused(bool value) async {
    paused = value;
    await _save();
  }

  Future<void> syncAll({bool silent = false}) async {
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

  Future<Map<String, dynamic>?> syncFolder(SyncFolderConfig folder, {bool silent = false}) async {
    if (paused || !folder.enabled || _running.contains(folder.id)) return null;
    if (!Directory(folder.localPath).existsSync()) {
      folder.lastError = 'Local folder is missing (external drive disconnected?)';
      await _save();
      return null;
    }
    _running.add(folder.id);
    if (!silent) {
      lastStatus = 'Syncing ${folder.name}…';
      notifyListeners();
    }
    try {
      final support = await getApplicationSupportDirectory();
      final syncDir = Directory(p.join(support.path, 'sync'));
      if (!syncDir.existsSync()) syncDir.createSync(recursive: true);
      final journal = p.join(syncDir.path, '${folder.id}.sqlite');
      final report = await NativeBridge.instance.syncRunAsync(
        handle: handle,
        baseUrl: server,
        token: token,
        remoteRootId: folder.remoteRootId,
        localPath: folder.localPath,
        journalPath: journal,
        deviceName: Platform.localHostname,
        excludedJson: jsonEncode(folder.excluded),
      );
      folder.lastReport = report;
      folder.lastSync = DateTime.now().toIso8601String();
      final errors = report['errors'];
      folder.lastError =
          (errors is List && errors.isNotEmpty) ? errors.map((e) => e.toString()).join('\n') : null;
      if (!silent) {
        lastStatus = '${folder.name}: ${report['uploaded']} uploaded, '
            '${report['downloaded']} downloaded, ${report['conflicts']} conflict(s).';
      }
      return report;
    } catch (e) {
      folder.lastError = e.toString();
      if (!silent) lastStatus = '${folder.name}: $e';
      return null;
    } finally {
      _running.remove(folder.id);
      await _save();
      await scanConflicts();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
