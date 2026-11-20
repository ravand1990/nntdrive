import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One kind of thing the local activity feed can record.
///
/// The values are stable identifiers: they are written into device-local
/// preferences, so renaming an enum value would orphan existing entries.
enum ActivityKind {
  uploaded,
  downloaded,
  moved,
  copied,
  renamed,
  deleted,
  failed,
  conflict;

  /// Short human label used in filters and row subtitles.
  String get label {
    switch (this) {
      case ActivityKind.uploaded:
        return 'Uploaded';
      case ActivityKind.downloaded:
        return 'Downloaded';
      case ActivityKind.moved:
        return 'Moved';
      case ActivityKind.copied:
        return 'Copied';
      case ActivityKind.renamed:
        return 'Renamed';
      case ActivityKind.deleted:
        return 'Deleted';
      case ActivityKind.failed:
        return 'Failed';
      case ActivityKind.conflict:
        return 'Conflict';
    }
  }

  /// Failures and conflicts also raise a notification until dismissed.
  bool get isNotification =>
      this == ActivityKind.failed || this == ActivityKind.conflict;

  static ActivityKind? fromName(Object? value) {
    if (value is! String) return null;
    for (final kind in ActivityKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// How many entries one account keeps. Bounded so a busy device cannot grow the
/// local log without limit.
const int activityEntryLimit = 500;

/// Default retention window. Older entries are dropped when the log is pruned.
const Duration activityRetention = Duration(days: 30);

/// Retention windows the activity settings offer, shortest first.
///
/// The window only controls how long this device keeps its local feed; nothing
/// is uploaded, and changing it never touches files or sync reports.
const List<Duration> activityRetentionChoices = [
  Duration(days: 7),
  Duration(days: 30),
  Duration(days: 90),
  Duration(days: 365),
];

/// Human label for a retention window, for example `30 days`.
String describeRetention(Duration retention) {
  final days = retention.inDays;
  if (days == 365) return '1 year';
  if (days == 7) return '7 days (1 week)';
  return days == 1 ? '1 day' : '$days days';
}

/// One readable activity row.
///
/// Everything here is device-local. [folder] and [subject] are local, decrypted
/// names; [folderRootId] and [itemId] are opaque remote identifiers. Nothing in
/// this class is ever sent to the backend, logged or included in diagnostics.
@immutable
class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.at,
    required this.kind,
    required this.folder,
    required this.subject,
    this.folderRootId,
    this.itemId,
    this.size,
    this.reason,
  });

  /// Random local identifier; also the dismissal key.
  final String id;
  final DateTime at;
  final ActivityKind kind;

  /// Local folder name the item belongs to, for example `Documents`.
  final String folder;

  /// Opaque remote root id when the entry belongs to a configured sync folder.
  final String? folderRootId;

  /// Opaque remote node id when the entry is about one remote item.
  final String? itemId;

  /// Local item name, or a short plain-text summary such as `12 items`.
  final String subject;

  final int? size;

  /// Short, secret-free explanation for failures and conflicts.
  final String? reason;

  bool get isNotification => kind.isNotification;

  /// `Copied budget.pdf`, used as the row title.
  String describe() => '${kind.label} $subject';

  /// Everything a local search can match on this row: the local name or
  /// summary, the folder, the kind and the secret-free reason.
  ///
  /// Derived on demand from device-local data; never persisted or sent.
  String get searchText => '${kind.label} $subject $folder ${reason ?? ''}';

  /// Whether this row matches a free-text [query].
  ///
  /// Matching is case-insensitive and every whitespace-separated word must
  /// appear somewhere in [searchText], so `failed docs` finds a failed row in
  /// the Documents folder. An empty or whitespace-only query matches every row.
  bool matchesQuery(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
    if (words.isEmpty) return true;
    final haystack = searchText.toLowerCase();
    return words.every((word) => haystack.contains(word));
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'kind': kind.name,
    'folder': folder,
    if (folderRootId != null) 'folderRootId': folderRootId,
    if (itemId != null) 'itemId': itemId,
    'subject': subject,
    if (size != null) 'size': size,
    if (reason != null) 'reason': reason,
  };

  /// Tolerant decoder: one unreadable row never discards the whole log.
  static ActivityEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final at = DateTime.tryParse(raw['at']?.toString() ?? '');
    final kind = ActivityKind.fromName(raw['kind']);
    final folder = raw['folder'];
    final subject = raw['subject'];
    if (id is! String || id.isEmpty) return null;
    if (at == null || kind == null) return null;
    if (folder is! String || subject is! String) return null;
    final size = raw['size'];
    final reason = raw['reason'];
    final folderRootId = raw['folderRootId'];
    final itemId = raw['itemId'];
    return ActivityEntry(
      id: id,
      at: at.toLocal(),
      kind: kind,
      folder: folder,
      subject: subject,
      folderRootId: folderRootId is String ? folderRootId : null,
      itemId: itemId is String ? itemId : null,
      size: size is int ? size : null,
      reason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }
}

/// The persisted part of the log: entries plus the notifications the user
/// already dismissed. Dismissal hides the notification, never the entry.
@immutable
class ActivitySnapshot {
  const ActivitySnapshot({this.entries = const [], this.dismissed = const {}});

  final List<ActivityEntry> entries;
  final Set<String> dismissed;
}

/// Storage seam: production uses local preferences, tests use memory.
abstract class ActivityStore {
  Future<ActivitySnapshot> load();
  Future<void> save(ActivitySnapshot snapshot);

  /// Retention window the user chose for this account, or null when they never
  /// changed it. Implementations that cannot persist it keep the default.
  Future<Duration?> loadRetention() async => null;

  /// Remembers the chosen retention window for this account.
  Future<void> saveRetention(Duration retention) async {}
}

/// Per-account preferences storage.
///
/// The account id keeps two accounts on one device from seeing each other's
/// history; the log never leaves the device.
class PreferencesActivityStore implements ActivityStore {
  const PreferencesActivityStore({required this.accountId});

  final String accountId;

  String get entriesKey => 'activity.$accountId';
  String get dismissedKey => 'activityDismissed.$accountId';
  String get retentionKey => 'activityRetention.$accountId';

  @override
  Future<Duration?> loadRetention() async {
    final prefs = await SharedPreferences.getInstance();
    final days = prefs.getInt(retentionKey);
    if (days == null || days < 1) return null;
    return Duration(days: days);
  }

  @override
  Future<void> saveRetention(Duration retention) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(retentionKey, retention.inDays);
  }

  @override
  Future<ActivitySnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = <ActivityEntry>[];
    final raw = prefs.getString(entriesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final row in decoded) {
            final entry = ActivityEntry.fromJson(row);
            if (entry != null) entries.add(entry);
          }
        }
      } catch (_) {
        // A corrupt log is discarded, never surfaced as a crash or a leak.
      }
    }
    final dismissed = <String>{};
    final rawDismissed = prefs.getString(dismissedKey);
    if (rawDismissed != null && rawDismissed.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawDismissed);
        if (decoded is List) {
          for (final id in decoded) {
            if (id is String && id.isNotEmpty) dismissed.add(id);
          }
        }
      } catch (_) {
        // Ignore an unreadable dismissal list: entries stay, notifications show.
      }
    }
    return ActivitySnapshot(entries: entries, dismissed: dismissed);
  }

  @override
  Future<void> save(ActivitySnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      entriesKey,
      jsonEncode([for (final entry in snapshot.entries) entry.toJson()]),
    );
    await prefs.setString(
      dismissedKey,
      jsonEncode(snapshot.dismissed.toList()),
    );
  }
}

/// Reads and writes the device-local activity feed for one account.
///
/// Recording is synchronous for the caller: the row appears immediately and the
/// save happens in the background, so an action never waits on disk. [flush]
/// awaits pending writes for tests and for sign-out.
class ActivityLog extends ChangeNotifier {
  ActivityLog({
    required this.store,
    required this.accountId,
    DateTime Function()? clock,
    this.maxEntries = activityEntryLimit,
    Duration retention = activityRetention,
  }) : _clock = clock ?? DateTime.now,
       _retention = retention,
       assert(maxEntries > 0),
       assert(retention.inDays >= 1);

  final ActivityStore store;
  final String accountId;
  final int maxEntries;
  final DateTime Function() _clock;

  Duration _retention;

  /// How far back this device keeps entries. The value a user chose in the
  /// settings is restored on [load]; it prunes only the local feed.
  Duration get retention => _retention;

  final List<ActivityEntry> _entries = [];
  final Set<String> _dismissed = {};
  bool _loaded = false;
  Future<void> _writes = Future<void>.value();

  bool get loaded => _loaded;

  /// Newest first.
  List<ActivityEntry> get entries => List.unmodifiable(_entries);

  Set<String> get dismissedIds => Set.unmodifiable(_dismissed);

  /// Undismissed failures and conflicts, newest first.
  List<ActivityEntry> get notifications => _entries
      .where((e) => e.isNotification && !_dismissed.contains(e.id))
      .toList();

  int get notificationCount => notifications.length;

  /// Loads the account's stored history once. A later call is a no-op.
  Future<void> load() async {
    if (_loaded) return;
    final snapshot = await store.load();
    final merged = <String, ActivityEntry>{
      for (final entry in snapshot.entries) entry.id: entry,
    };
    for (final entry in _entries) {
      // Entries recorded while loading (an action finished early) win.
      merged[entry.id] = entry;
    }
    _entries
      ..clear()
      ..addAll(merged.values);
    _dismissed.addAll(snapshot.dismissed);
    _loaded = true;
    try {
      final stored = await store.loadRetention();
      if (stored != null && stored.inDays >= 1) _retention = stored;
    } catch (_) {
      // An unreadable preference keeps the default window for this session.
    }
    _prune(notify: false);
    _sort();
    notifyListeners();
  }

  /// Records one row. [subject] is a local name or a plain-text summary.
  void record({
    required ActivityKind kind,
    required String folder,
    required String subject,
    String? folderRootId,
    String? itemId,
    int? size,
    String? reason,
    DateTime? at,
    String? id,
  }) {
    final entry = ActivityEntry(
      id: id ?? _newId(),
      at: (at ?? _clock()).toLocal(),
      kind: kind,
      folder: folder,
      subject: subject,
      folderRootId: folderRootId,
      itemId: itemId,
      size: size,
      reason: reason,
    );
    _entries.insert(0, entry);
    _prune(notify: false);
    notifyListeners();
    _persist();
  }

  /// Hides one notification. The entry itself stays in the feed.
  void dismiss(String id) {
    if (!_entries.any((entry) => entry.id == id)) return;
    if (!_dismissed.add(id)) return;
    notifyListeners();
    _persist();
  }

  void dismissAll() {
    var changed = false;
    for (final entry in notifications) {
      changed = _dismissed.add(entry.id) || changed;
    }
    if (!changed) return;
    notifyListeners();
    _persist();
  }

  /// Applies a new retention window for this account.
  ///
  /// Rows older than the new window are dropped immediately, then the pruned
  /// feed and the choice are saved. A window shorter than a day is ignored, and
  /// changing it never touches files, sync folders or sync reports.
  Future<void> setRetention(Duration retention) async {
    if (retention.inDays < 1 || retention == _retention) return;
    _retention = retention;
    _prune(notify: false);
    notifyListeners();
    try {
      await store.saveRetention(retention);
    } catch (_) {
      // The window still applies for this session; the next change retries.
    }
    _persist();
    await flush();
  }

  /// Clears the whole history, for example on sign-out.
  Future<void> clear() async {
    _entries.clear();
    _dismissed.clear();
    notifyListeners();
    _persist();
    await flush();
  }

  /// Entries matching every supplied filter, newest first.
  ///
  /// [query] is the local free-text search; it only looks at the bounded
  /// in-memory log, so it never reads files, hits the network or touches names
  /// that are not already decrypted for this session.
  List<ActivityEntry> filtered({
    ActivityKind? kind,
    String? folder,
    String? folderRootId,
    DateTime? since,
    String? query,
  }) {
    return _entries.where((entry) {
      if (kind != null && entry.kind != kind) return false;
      if (folder != null && entry.folder != folder) return false;
      if (folderRootId != null && entry.folderRootId != folderRootId) {
        return false;
      }
      if (since != null && entry.at.isBefore(since)) return false;
      if (query != null && !entry.matchesQuery(query)) return false;
      return true;
    }).toList();
  }

  /// Folders that currently have entries, with their row counts.
  Map<String, int> get folderCounts {
    final counts = <String, int>{};
    for (final entry in _entries) {
      counts[entry.folder] = (counts[entry.folder] ?? 0) + 1;
    }
    return counts;
  }

  /// Plain-text report for troubleshooting.
  ///
  /// [includeLocalNames] false replaces every local name with an opaque id (or
  /// `unknown item`) so the report can be shared without disclosing filenames.
  String exportText({required bool includeLocalNames}) {
    final buffer = StringBuffer(
      '# NNTDrive activity export (device-local, ${_entries.length} entries)\n',
    );
    if (!includeLocalNames) {
      buffer.writeln('# Names and folders are replaced by opaque identifiers.');
    }
    for (final entry in _entries) {
      final subject = includeLocalNames
          ? entry.subject
          : (entry.itemId ?? 'unknown item');
      final folder = includeLocalNames
          ? entry.folder
          : (entry.folderRootId ?? 'unknown folder');
      final parts = <String>[
        formatActivityTime(entry.at),
        entry.kind.label,
        folder,
        subject,
        if (entry.size != null) '${entry.size} bytes',
        if (entry.reason != null) entry.reason!,
      ];
      buffer.writeln(parts.join(' · '));
    }
    return buffer.toString();
  }

  /// Awaits queued preference writes.
  Future<void> flush() => _writes;

  String _newId() {
    final micros = _clock().toUtc().microsecondsSinceEpoch;
    _sequence = (_sequence + 1) % 100000;
    return 'a$micros-$_sequence';
  }

  int _sequence = 0;

  void _sort() {
    _entries.sort((a, b) => b.at.compareTo(a.at));
  }

  void _prune({bool notify = true}) {
    final cutoff = _clock().toLocal().subtract(retention);
    _entries.removeWhere((entry) => entry.at.isBefore(cutoff));
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    final live = {for (final entry in _entries) entry.id};
    _dismissed.removeWhere((id) => !live.contains(id));
    if (notify) notifyListeners();
  }

  void _persist() {
    final snapshot = ActivitySnapshot(
      entries: List.of(_entries),
      dismissed: Set.of(_dismissed),
    );
    _writes = _writes.then((_) => store.save(snapshot)).catchError((Object _) {
      // A failed save must not break the action that was already applied;
      // the in-memory feed stays usable and is retried on the next record.
    });
  }
}

/// Row timestamp: `20 Nov 14:05`, in local time.
String formatActivityTime(DateTime at) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = at.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} $hour:$minute';
}
