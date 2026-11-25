import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'account_roots.dart';
import 'device_onboarding.dart';
import 'device_name.dart';
import 'keyfile_refresh.dart';
import 'key_rotation.dart';
import 'app_layout.dart';
import 'session_navigation.dart';
import 'app_theme.dart';
import 'activity_log.dart';
import 'activity_page.dart';
import 'activity_sync.dart';
import 'space_notice.dart';
import 'account_search.dart';
import 'search_page.dart';
import 'search_navigation.dart';
import 'storage_usage_page.dart';
import 'search_status.dart';
import 'desktop_host.dart';
import 'desktop_instance.dart';
import 'desktop_lifecycle.dart';
import 'secure_keyfile.dart';
import 'session_operations.dart';
import 'local_availability.dart';
import 'browser_listing_states.dart';
import 'browser_views.dart';
import 'appearance.dart';
import 'browser_file_details.dart';
import 'browser_commands.dart';
import 'browser_breadcrumbs.dart';
import 'file_rename.dart';
import 'file_move.dart';
import 'file_copy.dart';
import 'item_actions.dart';
import 'download_cache.dart';
import 'cache_page.dart';
import 'cache_settings.dart';
import 'preview.dart';
import 'preview_page.dart';
import 'login_autostart.dart';
import 'login_autostart_settings.dart';
import 'move_dialog.dart';
import 'folder_picker.dart';
import 'discard_on_back.dart';
import 'rename_dialog.dart';
import 'native.dart';
import 'reference_backfill.dart';
import 'sync_controller.dart';
import 'sync_page.dart';
import 'updater.dart';
import 'update_checks.dart';
import 'update_prompt.dart';
import 'android_update.dart';
import 'android_update_prompt.dart';
import 'trash_page.dart';
import 'version_history.dart';

const _uuid = Uuid();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android draws behind the system bars; the icon style follows the theme.
  await applyEdgeToEdgeSystemUi();
  DesktopInstance? instance;
  if (Platform.isWindows || Platform.isLinux) {
    try {
      instance = await DesktopInstance.acquire(await getApplicationSupportDirectory());
    } catch (_) {
      // Do not read settings, unlock, or open journals without ownership.
      runApp(MaterialApp(home: Scaffold(body: Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('NNTDrive is already running, or session ownership is unavailable.\n'
              'Open the existing window or tray icon. No new sync session was started.',
              textAlign: TextAlign.center),
          TextButton(onPressed: () => exit(1), child: const Text('Close')),
        ],
      )))));
      return;
    }
  }
  final prefs = await SharedPreferences.getInstance();
  runApp(NntDriveApp(prefs: prefs, instance: instance));
}

class Session {
  Session({
    required this.server,
    required this.token,
    required this.handle,
    required this.accountId,
    required this.email,
    required this.operations,
    this.searchListingWorker = runSearchListingDecode,
  });
  // Test seam for suspending parsing while exercising real Session drain.
  final Future<List<RemoteFile>> Function(List<int>) searchListingWorker;
  final SessionOperations operations;
  late final AccountSearch search = AccountSearch(
    // All automatic refresh work remains owned by this session index.
    handle: handle,
    operations: operations,
    list: (parent) => ApiClient(baseUrl: server, token: token)
        .listFilesForSearch(parentId: parent, decode: searchListingWorker),
    decrypt: (file) => NativeBridge.instance.openName(handle, file.id, file.nameEnc),
    decryptBatch: (files) => NativeBridge.instance.openNamesAsync(handle,
        files.map((f) => (id: f.id, nameEnc: f.nameEnc)).toList()),
    // This local native operation validates a live handle even with an empty
    // index. The random ciphertext is discarded; it is never sent or persisted.
    authorize: () { NativeBridge.instance.sealName(handle, '00000000-0000-0000-0000-000000000000', ''); },
  );
  final String server;
  final String token;
  final int handle;
  final String accountId;
  final String email;
  SyncController? sync;

  ApiClient bindApi(ApiClient api) {
    api.onAccountChanged = accountChanged;
    return api;
  }

  /// Own publication plus invalidation, not transfer byte notifications.
  Future<Map<String, dynamic>> upload({required String fileId,
      required String revisionId, required String parentRevision,
      required String path}) => operations.run(handle, () async {
    final result = await NativeBridge.instance.uploadAsync(handle: handle,
      baseUrl: server, token: token, fileId: fileId, revisionId: revisionId,
      parentRevision: parentRevision, path: path);
    accountChanged();
    return result;
  });

  void accountChanged() {
    unawaited(search.refreshAfterMutation(inspectStatuses: (snapshot, cancelled) async {
      final controller = sync;
      if (controller == null || !controller.loaded) return {};
      return inspectSearchStatuses(snapshot: snapshot,
        folders: controller.folders, cancelled: cancelled);
    }));
  }
}

class NntDriveApp extends StatefulWidget {
  const NntDriveApp({super.key, required this.prefs, this.instance, this.apiFactory,
    this.updateCheck, this.androidUpdateCheck, this.keyfileVault, this.loginAutostart});
  final SharedPreferences prefs;
  final DesktopInstance? instance;
  /// Transport seam for exercising unlock/onboarding/session lifecycle together.
  final ApiClient Function(String server, String token)? apiFactory;
  /// Feed seams; the app still owns scheduling, presentation and confirmation.
  final Future<UpdateInfo?> Function()? updateCheck;
  final Future<AndroidUpdateInfo?> Function()? androidUpdateCheck;
  /// Credential-store seam; defaults to this platform's OS keyring.
  final KeyfileVault? keyfileVault;
  final LoginAutostart? loginAutostart;

  @override
  State<NntDriveApp> createState() => _NntDriveAppState();
}

class _NntDriveAppState extends State<NntDriveApp> {
  ApiClient _authenticatedApi(String server, String token) =>
      widget.apiFactory?.call(server, token) ?? ApiClient(baseUrl: server, token: token);
  late ThemeMode _themeMode;
  late BrowserDensity _browserDensity;
  late String _server;
  String? _token;
  String? _keyfile;
  late final KeyfileVault _keyfileVault = widget.keyfileVault ??
      KeyfileVault(
        store: createPlatformCredentialStore(),
        prefs: widget.prefs,
      );
  String? _accountId;
  String? _email;
  Session? _session;
  bool _deviceReady = false;
  bool _renamingDevice = false;
  SyncController? _sync;
  ActivityLog? _activity;
  DesktopLifecycle? _desktop;
  String? _desktopError;
  late final LoginAutostartSettings _autostart = LoginAutostartSettings(
    prefs: widget.prefs,
    registration: widget.loginAutostart ?? platformLoginAutostart(),
    executable: Platform.resolvedExecutable,
  );

  void _autostartChanged() {
    if (mounted) setState(() {});
  }
  String? _trayState;
  String? _shutdownError;
  bool _ending = false;
  Future<void>? _endFuture;
  Future<void>? _authFuture;
  final _fileOperations = SessionOperations();
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final UpdateChecks _updates = UpdateChecks(
    check: () async => widget.updateCheck != null ? widget.updateCheck!()
        : Updater(await Updater.loadConfig()).check(),
    prompt: (info) async {
      final context = _navigatorKey.currentContext;
      if (!mounted || context == null || !context.mounted) return false;
      return promptUpdate(context, info, _formatBytes(info.size));
    },
  );

  late final AutomaticUpdateChecks<AndroidUpdateInfo> _androidUpdates =
      AutomaticUpdateChecks<AndroidUpdateInfo>(
    check: () async => widget.androidUpdateCheck != null
        ? widget.androidUpdateCheck!()
        : AndroidUpdater(config: await Updater.loadConfig()).check(),
    isSkipped: (info, prefs) async =>
        prefs.getInt(androidSkippedVersionCodeKey) == info.versionCode,
    prompt: (info) async {
      final context = _navigatorKey.currentContext;
      if (!mounted || context == null || !context.mounted) return false;
      final updater = AndroidUpdater(config: await Updater.loadConfig());
      if (!mounted || !context.mounted) return false;
      return promptAndroidUpdate(context, updater, info, _formatBytes(info.size));
    },
  );

  AutomaticUpdateChecks<Object>? get _automaticUpdates {
    if (defaultTargetPlatform == TargetPlatform.android) return _androidUpdates;
    if (Updater.supported) return _updates;
    return null;
  }

  @override
  void dispose() {
    _autostart.removeListener(_autostartChanged);
    _autostart.dispose();
    unawaited(_keyfileVault.dispose());
    _updates.dispose();
    _androidUpdates.dispose();
    _desktop?.dispose();
    _sync?.removeListener(_updateTray);
    _sync?.dispose();
    _activity?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final theme = widget.prefs.getInt('theme') ?? 0;
    _themeMode = theme >= 0 && theme < ThemeMode.values.length
        ? ThemeMode.values[theme] : ThemeMode.system;
    _browserDensity = BrowserDensity.fromPreference(
        widget.prefs.getString('browserDensity'));
    _server = widget.prefs.getString('server') ?? 'http://127.0.0.1:8080';
    _token = widget.prefs.getString('token');
    _keyfile = widget.prefs.getString('keyfile');
    _accountId = widget.prefs.getString('accountId');
    _email = widget.prefs.getString('email');
    _autostart.addListener(_autostartChanged);
    unawaited(_loadStoredKeyfile());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _automaticUpdates?.start();
      if (mounted) unawaited(_autostart.initialize());
      if (widget.instance != null) unawaited(_startDesktop());
    });
  }

  void _setTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    widget.prefs.setInt('theme', mode.index);
  }

  void _setBrowserDensity(BrowserDensity density) {
    setState(() => _browserDensity = density);
    widget.prefs.setString('browserDensity', density.name);
  }

  /// Adopts the wrapped keyfile from the OS credential store, after a
  /// migration or when preferences no longer hold it. An in-memory value from
  /// this start is never replaced.
  Future<void> _loadStoredKeyfile() async {
    try {
      final stored = await _keyfileVault.load();
      if (!mounted || _ending || stored == null || _keyfile != null) return;
      setState(() => _keyfile = stored);
    } catch (_) {
      // The preferences value read in initState remains authoritative.
    }
  }

  Future<void> _startDesktop() async {
    _desktop = DesktopLifecycle(
      host: PluginDesktopHost(),
      drain: () => _endSession(signOut: false),
      quit: () async {
        await widget.instance!.release();
        exit(0);
      },
      togglePause: () async {
        final sync = _sync;
        if (!_ending && _deviceReady && sync != null && sync.loaded &&
            sync.deviceNameConfirmed) {
          await sync.setPaused(!sync.paused);
        }
      },
      onError: (message) {
        if (mounted) setState(() => _desktopError = message);
      },
    );
    await _desktop!.start();
    _updateTray();
    if (mounted) setState(() {});
  }

  Future<String?> _setLoginAutostart(bool enabled) => _autostart.setEnabled(enabled);

  void _updateTray() {
    if (_desktop?.ready != true) return;
    final sync = _sync;
    final status = _ending ? 'Finishing active operations…'
        : sync == null ? 'Sync paused: vault locked'
        : sync.paused ? 'Sync paused by user'
        : sync.syncing || sync.folders.any((f) => f.running) ? 'Sync running'
        : sync.folders.any((f) => f.hasErrors) ? 'Sync needs attention — open NNTDrive'
        : sync.conflictCount > 0 ? 'Sync conflicts — open NNTDrive'
        : sync.folders.isEmpty ? 'No sync folders selected' : 'Sync scheduled';
    final canPause = sync != null && sync.loaded && sync.deviceNameConfirmed &&
        _deviceReady && !_ending;
    final state = '$status|$canPause|${sync?.paused ?? true}';
    if (_trayState == state) return; // Byte-progress events do not rebuild menus.
    _trayState = state;
    unawaited(_desktop?.update(status,
        canPause: canPause, paused: sync?.paused ?? true));
  }

  Future<void> _completeAuth({
    required String server,
    required String token,
    required String keyfileJson,
    required String accountId,
    required String email,
    required String password,
  }) {
    if (_ending || (_desktop?.closing ?? false)) {
      return Future.error(StateError('Session is closing'));
    }
    return _authFuture = _doCompleteAuth(server: server, token: token,
        keyfileJson: keyfileJson, accountId: accountId, email: email, password: password);
  }

  Future<void> _doCompleteAuth({
    required String server,
    required String token,
    required String keyfileJson,
    required String accountId,
    required String email,
    required String password,
  }) async {
    // Another device may have rotated the account master key since this device
    // saved its keyfile. Prefer the newer published copy (which still carries
    // the previous epochs) so pre-rotation revisions stay readable; an offline
    // or refused fetch keeps the local copy. Both stay password-wrapped.
    final effectiveKeyfile = await newestKeyfileJson(
      api: _authenticatedApi(server, token),
      storedJson: keyfileJson,
      accountId: accountId,
    );
    var unlockKeyfile = effectiveKeyfile;
    late Map<String, dynamic> unlocked;
    try {
      unlocked = await NativeBridge.instance.unlockAsync(unlockKeyfile, password);
    } catch (_) {
      // A published keyfile this device cannot open (corrupt copy, rollback or
      // a different password) must not lock the local one out. A wrong password
      // fails again here and surfaces as before.
      if (effectiveKeyfile == keyfileJson) rethrow;
      unlockKeyfile = keyfileJson;
      unlocked = await NativeBridge.instance.unlockAsync(unlockKeyfile, password);
    }
    var adopted = false;
    try {
      if (!mounted || _ending) return;
      await widget.prefs.setString('server', server);
      await widget.prefs.setString('token', token);
      await _keyfileVault.save(unlockKeyfile);
      await widget.prefs.setString('accountId', accountId);
      await widget.prefs.setString('email', email);
      if (!mounted || _ending) return;
      final activity = ActivityLog(
        store: PreferencesActivityStore(accountId: accountId),
        accountId: accountId,
      );
      _activity = activity;
      final session = Session(server: server, token: token,
        handle: unlocked['handle'] as int, accountId: accountId,
        email: email, operations: _fileOperations);
      final sync = SyncController(
        server: server,
        token: token,
        handle: unlocked['handle'] as int,
        api: session.bindApi(_authenticatedApi(server, token)),
        deviceNameConfirmed: false,
        onRunFinished: (folder, report) =>
            recordSyncRunActivity(activity, folder, report),
      );
      session.sync = sync;
      _sync = sync;
      sync.addListener(_updateTray);

      setState(() {
        _server = server;
        _token = token;
        _keyfile = unlockKeyfile;
        _accountId = accountId;
        _email = email;
        _session = session;
      });
      _deviceReady = false;
      _renamingDevice = false;
      adopted = true;
      _updateTray();
    } finally {
      if (!adopted) NativeBridge.instance.lock(unlocked['handle'] as int);
    }
  }

  void _signOut() => unawaited(_endSession(signOut: true).catchError((Object _) {
    // The failed drain stays locked down; the overlay exposes explicit retry.
  }));

  Future<void> _deviceConfirmed() async {
    final sync = _sync;
    if (_ending || !mounted || sync == null) return;
    sync.deviceNameConfirmed = true;
    try {
      if (sync.loaded) {
        await sync.refreshAccountRoots();
      } else {
        await sync.load();
      }
    } catch (_) {
      sync.deviceNameConfirmed = false;
      rethrow;
    }
    if (_ending || !mounted) return;
    if (sync.rootsError != null || sync.deviceRootNodeId == null) {
      sync.deviceNameConfirmed = false;
      throw StateError('Device space unavailable');
    }
    sync.start();
    setState(() { _deviceReady = true; _renamingDevice = false; });
    _updateTray();
    // Do not await a modal prompt from the naming submission. Publish the new
    // home first, then retry failed/unavailable startup offers without a day gate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_ending) unawaited(_automaticUpdates?.retryPending());
    });
  }

  void _renameDevice() {
    _sync?.deviceNameConfirmed = false;
    setState(() { _deviceReady = false; _renamingDevice = true; });
  }

  /// Rotates the account key from the unlocked session and stores the new
  /// keyfile. The bridge keeps the live handle on the rotated ring, so the
  /// session keeps working; the password and recovery code stay in the dialog.
  Future<bool> _rotateAccountKey() async {
    final session = _session;
    final keyfile = _keyfile;
    final context = _navigatorKey.currentContext;
    if (_ending || session == null || keyfile == null || context == null) return false;
    final outcome = await showDialog<KeyRotationOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (context) => RotateAccountKeyDialog(
        rotate: (password, recoveryCode) => KeyRotationOutcome.attempt(
          (password, recoveryCode) => NativeBridge.instance.rotateAccountKeyAsync(
            session.handle,
            {
              'baseUrl': session.server,
              'token': session.token,
              'keyfile': keyfile,
              'password': password,
              if (recoveryCode != null) 'recoveryCode': recoveryCode,
            },
          ),
          password,
          recoveryCode,
        ),
      ),
    );
    final rotated = outcome?.keyfileJson;
    if (rotated == null) return false;
    try {
      await _keyfileVault.save(rotated);
    } catch (_) {
      // The rotation is already published, so the next unlock fetches the newer
      // keyfile from the server even if this local write failed. The session
      // keeps the rotated key in memory either way.
    }
    if (!mounted) return true;
    setState(() => _keyfile = rotated);
    return true;
  }

  Future<void> _endSession({required bool signOut}) =>
      _endFuture ??= _finishSession(signOut: signOut).catchError((Object error, StackTrace stack) {
        _endFuture = null;
        if (mounted) {
          setState(() => _shutdownError =
              'Shutdown could not finish. No new work is allowed. Retry Quit or Sign out.');
        }
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _finishSession({required bool signOut}) async {
    if (mounted) {
      setState(() {
        _ending = true;
        _shutdownError = null;
      });
    }
    _updateTray();
    try { await _authFuture; } catch (_) { /* Failed unlock has no session. */ }
    final session = _session;
    final sync = _sync;
    session?.search.close(); // Clear plaintext and cancel indexing before drain.
    await Future.wait([
      if (sync != null) sync.stopAndDrain(),
      if (session != null) _fileOperations.drain(session.handle),
    ]);
    if (session != null) {
      await NativeBridge.instance.drainSession(session.handle);
      NativeBridge.instance.lock(session.handle);
    }
    sync?.removeListener(_updateTray);
    if (!signOut) return; // Quit preserves password-wrapped login settings.
    if (session != null) {
      unawaited(ApiClient(baseUrl: session.server, token: session.token)
          .logout().then<void>((_) {}, onError: (Object _) {}));
    }
    // Signing out removes this account's device-local history and keyfile.
    await _activity?.clear();
    await widget.prefs.remove('token');
    await _keyfileVault.clear();
    await widget.prefs.remove('accountId');
    if (!mounted) return;
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _session = null;
      _sync = null;
      _token = null;
      _keyfile = null;
      _accountId = null;
      _ending = false;
    });
    // FilesPage removes its listener when it is unmounted on this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => sync?.dispose());
    _endFuture = null;
    _updateTray();
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (_session != null && !_deviceReady) {
      final session = _session!;
      home = DeviceOnboardingPage(
        key: ValueKey('device:${session.handle}:$_renamingDevice'),
        naming: DeviceNaming(api: session.bindApi(_authenticatedApi(session.server, session.token)),
          handle: session.handle, server: session.server, accountId: session.accountId),
        operations: _fileOperations, onReady: _deviceConfirmed,
        onSignOut: _signOut, force: _renamingDevice,
      );
    } else if (_session != null) {
      home = FilesPage(
        key: ValueKey('${_session!.accountId}:${_session!.handle}'),
        session: _session!,
        sync: _sync!,
        activity: _activity,
        operations: _fileOperations,
        updates: _automaticUpdates ?? _updates,
        api: widget.apiFactory?.call(_session!.server, _session!.token),
        themeMode: _themeMode,
        onTheme: _setTheme,
        browserDensity: _browserDensity,
        onBrowserDensity: _setBrowserDensity,
        onSignOut: _signOut,
        onRenameDevice: _renameDevice,
        onRotateAccountKey: _rotateAccountKey,
        loginAutostartEnabled: _autostart.enabled,
        loginAutostartError: _autostart.error,
        onSetLoginAutostart: _setLoginAutostart,
      );
    } else if (_token != null && _keyfile != null && _accountId != null && _email != null) {
      home = UnlockPage(
        server: _server,
        email: _email!,
        keyfileJson: _keyfile!,
        accountId: _accountId!,
        token: _token!,
        onUnlocked: (password) => _completeAuth(
          server: _server,
          token: _token!,
          keyfileJson: _keyfile!,
          accountId: _accountId!,
          email: _email!,
          password: password,
        ),
        onSignOut: _signOut,
        startupControl: LoginAutostartControl(settings: _autostart),
      );
    } else {
      home = LoginPage(initialServer: _server, onAuthenticated: _completeAuth,
        startupControl: LoginAutostartControl(settings: _autostart));
    }
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'NNTDrive',
      debugShowCheckedModeBanner: false,
      theme: buildNntDriveTheme(Brightness.light),
      darkTheme: buildNntDriveTheme(Brightness.dark),
      themeMode: _themeMode,
      home: home,
      builder: (context, child) => SystemUiStyleScope(
        child: Column(children: [
          Expanded(child: Stack(children: [
            FocusScope(canRequestFocus: !_ending,
                child: AbsorbPointer(absorbing: _ending, child: child!)),
            if (_ending) Positioned.fill(child: Material(
              color: Theme.of(context).busyOverlayColor, child: Center(child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_shutdownError == null) const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_shutdownError ?? 'Finishing active operations before locking the vault…'),
                  if (_shutdownError != null) TextButton(onPressed: _signOut,
                      child: const Text('Retry Sign out')),
                ],
              )),
            )),
          ])),
          if (widget.instance != null) Material(child: SafeArea(top: false,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Expanded(child: Text(_desktopError ?? (_desktop?.ready == true
                    ? 'Close keeps NNTDrive in the tray. Hiding does not lock the vault.'
                    : 'Starting desktop session…'))),
                TextButton(onPressed: _desktop == null ? null : () => _desktop!.requestQuit(),
                    child: const Text('Quit NNTDrive')),
              ]),
            ),
          )),
        ])),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.initialServer, required this.onAuthenticated,
    this.startupControl});
  final Widget? startupControl;
  final String initialServer;
  final Future<void> Function({
    required String server,
    required String token,
    required String keyfileJson,
    required String accountId,
    required String email,
    required String password,
  }) onAuthenticated;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _server = TextEditingController(text: widget.initialServer);
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _setupRequired = false;
  bool _registrationAllowed = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkSetup();
  }

  Future<void> _checkSetup() async {
    final server = _server.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (server.isEmpty) return;
    try {
      final status = await ApiClient(baseUrl: server).setupStatus();
      if (!mounted) return;
      setState(() {
        _setupRequired = status.setupRequired;
        _registrationAllowed = status.registrationAllowed || status.setupRequired;
        if (status.setupRequired) _register = true;
      });
    } catch (_) {
      // Server unreachable or old backend: leave the normal sign-in visible.
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final server = _server.text.trim().replaceAll(RegExp(r'/+$'), '');
    final email = _email.text.trim();
    final password = _password.text;
    if (server.isEmpty || email.isEmpty || password.length < 8) {
      setState(() => _error = 'Enter a server, email and a password of at least 8 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ApiClient(baseUrl: server);
      final bridge = NativeBridge.instance;
      if (_register) {
        final account = await bridge.generateAccountAsync(password);
        final device = bridge.deviceIdentity();
        final accountId = account['account_id'] as String;
        final response = await api.register(
          accountId: accountId,
          email: email,
          verifier: account['verifier'] as String,
          keyfile: account['keyfile'] as Map<String, dynamic>,
          recoveryKit: account['recovery_kit'] as Map<String, dynamic>?,
          device: {
            'id': _uuid.v4(),
            'name': 'Device',
            'platform': Platform.operatingSystem,
            'public_key': device['public_key'],
          },
        );
        final token = response['token'] as String;
        final isAdmin = response['is_admin'] == true;

        String? adminToken;
        String? tokenError;
        if (isAdmin) {
          api.token = token;
          try {
            adminToken = await api.createToken('admin-dashboard');
          } catch (e) {
            tokenError = e.toString();
          }
        }

        final code = account['recovery_code'] as String;
        if (mounted) {
          await _showSetupComplete(
            context: context,
            server: server,
            email: email,
            accountId: accountId,
            isAdmin: isAdmin,
            recoveryCode: code,
            adminToken: adminToken,
            tokenError: tokenError,
          );
        }
        await widget.onAuthenticated(
          server: server,
          token: token,
          keyfileJson: jsonEncode(account['keyfile']),
          accountId: accountId,
          email: email,
          password: password,
        );
      } else {
        final accountId = await api.lookupAccountId(email);
        final verifier = await bridge.deriveVerifierAsync(password, accountId);
        final response = await api.loginWithVerifier(
          email,
          verifier,
          device: {
            'id': _uuid.v4(),
            'name': 'Device',
            'platform': Platform.operatingSystem,
            'public_key': bridge.deviceIdentity()['public_key'],
          },
        );
        final keyfile = response['keyfile'];
        if (keyfile == null) {
          throw const FormatException('Server did not return a keyfile for this account.');
        }
        await widget.onAuthenticated(
          server: server,
          token: response['token'] as String,
          keyfileJson: jsonEncode(keyfile),
          accountId: accountId,
          email: email,
          password: password,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showSetupComplete({
    required BuildContext context,
    required String server,
    required String email,
    required String accountId,
    required bool isAdmin,
    required String recoveryCode,
    required String? adminToken,
    String? tokenError,
  }) async {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13);
    Widget copyRow(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.labelLarge),
                    SelectableText(value, style: mono),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                onPressed: () => Clipboard.setData(ClipboardData(text: value)),
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
        );

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Theme.of(context).connectedIndicatorColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(isAdmin ? 'First-time setup complete' : 'Account created'),
            ),
          ],
        ),
        content: SizedBox(
          width: 580,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isAdmin
                      ? 'You are the administrator. Store the recovery code offline and use the admin token for the dashboard. Both are shown only once.'
                      : 'Store the recovery code offline. It is shown only once.',
                ),
                const SizedBox(height: 12),
                Text('Server', style: Theme.of(context).textTheme.labelLarge),
                SelectableText(server, style: mono),
                Text('Email', style: Theme.of(context).textTheme.labelLarge),
                SelectableText(email, style: mono),
                Text('Account id', style: Theme.of(context).textTheme.labelLarge),
                SelectableText(accountId, style: mono),
                const Divider(height: 26),
                copyRow('Recovery code (offline, never on the server)', recoveryCode),
                if (adminToken != null) ...[
                  copyRow('Admin API token (paste at $server/admin)', adminToken),
                  const SizedBox(height: 6),
                  const Text(
                    'The admin token expires after 90 days. Keep it private.',
                    style: TextStyle(fontSize: 12),
                  ),
                ] else if (isAdmin) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Could not mint the admin token automatically${tokenError == null ? '' : ': $tokenError'}. '
                    'Run scripts/mint-admin-token.sh $email admin to create one.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              final all = StringBuffer()
                ..writeln('NNTDrive account')
                ..writeln('server: $server')
                ..writeln('email: $email')
                ..writeln('account_id: $accountId')
                ..writeln('recovery_code: $recoveryCode');
              if (adminToken != null) {
                all.writeln('admin_token: $adminToken');
                all.writeln('admin_url: $server/admin');
              }
              Clipboard.setData(ClipboardData(text: all.toString()));
            },
            child: const Text('Copy all'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I saved these — continue'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_outlined, size: 40, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Text('NNTDrive',
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('End-to-end encrypted storage on Usenet',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                if (_setupRequired) ...[
                  const SizedBox(height: 18),
                  Card(
                    color: theme.colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.rocket_launch_outlined,
                              color: theme.colorScheme.onPrimaryContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Welcome! This server has no accounts yet. Create the first '
                              'administrator below: your encryption keys are generated on this '
                              'device, then you will get a recovery code and a one-time admin token.',
                              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                if (_registrationAllowed)
                  SegmentedButton<bool>(
                    segments: [
                      if (!_setupRequired)
                        const ButtonSegment(value: false, label: Text('Sign in')),
                      ButtonSegment(
                        value: true,
                        label: Text(_setupRequired ? 'First-time setup' : 'Create account'),
                      ),
                    ],
                    selected: {_register || _setupRequired},
                    onSelectionChanged: _busy || _setupRequired
                        ? null
                        : (s) => setState(() {
                              _register = s.first;
                              _error = null;
                            }),
                  )
                else
                  Text('Registration is disabled. Sign in with an existing account.',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 18),
                TextField(
                  controller: _server,
                  decoration: InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://drive.example.com',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'Check server / setup state',
                      onPressed: _busy ? null : _checkSetup,
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  onSubmitted: _busy ? null : (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    helperText: _register
                        ? 'Argon2id protects your key; at least 8 characters.'
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _busy
                        ? const SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_setupRequired
                            ? 'Create administrator account'
                            : (_register ? 'Create encrypted account' : 'Unlock')),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 22),
                if (widget.startupControl != null) widget.startupControl!,
                Text(
                  'Your password never leaves this device. The server receives only an Argon2id verifier and ciphertext.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class UnlockPage extends StatefulWidget {
  const UnlockPage({
    super.key,
    required this.server,
    required this.email,
    required this.keyfileJson,
    required this.accountId,
    required this.token,
    required this.onUnlocked,
    required this.onSignOut,
    this.startupControl,
  });
  final Widget? startupControl;
  final String server;
  final String email;
  final String keyfileJson;
  final String accountId;
  final String token;
  final Future<void> Function(String password) onUnlocked;
  final VoidCallback onSignOut;

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onUnlocked(_password.text);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, size: 48),
                  const SizedBox(height: 14),
                  Text('Unlock NNTDrive', textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(widget.email, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  const Text(
                    'Sync paused: vault locked. Unlock to allow synchronization.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofocus: true,
                    onSubmitted: _busy ? null : (_) => _unlock(),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy ? null : _unlock,
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Unlock'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  TextButton(
                    onPressed: widget.onSignOut,
                    child: const Text('Use another account / server'),
                  ),
                  if (widget.startupControl != null) widget.startupControl!,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.updates,
    required this.session,
    required this.sync,
    required this.operations,
    required this.themeMode,
    required this.onTheme,
    required this.onSignOut,
    this.api,
    this.browserDensity = BrowserDensity.comfortable,
    this.onBrowserDensity,
    this.activity,
    this.onRenameDevice,
    this.onRotateAccountKey,
    this.loginAutostartEnabled = false,
    this.loginAutostartError,
    this.onSetLoginAutostart,
  });
  final Session session;
  final SyncController sync;

  /// Session-owned device-local activity feed; tests may omit it.
  final ActivityLog? activity;
  final SessionOperations operations;
  final AutomaticUpdateChecks<Object> updates;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onTheme;
  final BrowserDensity browserDensity;
  final ValueChanged<BrowserDensity>? onBrowserDensity;
  final VoidCallback onSignOut;

  /// Test seam: a page built by a test talks to this client instead of
  /// constructing one from the session.
  final ApiClient? api;
  final VoidCallback? onRenameDevice;

  /// Rotates the account key after a revoke that requires it. Owned by the app
  /// because the rotated keyfile replaces the stored one; tests may omit it.
  final Future<bool> Function()? onRotateAccountKey;

  /// Desktop login-item state, owned by the app so startup can re-register it.
  final bool loginAutostartEnabled;
  final String? loginAutostartError;
  final Future<String?> Function(bool enabled)? onSetLoginAutostart;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  late final ApiClient _api = widget.session.bindApi(widget.api ??
      ApiClient(baseUrl: widget.session.server, token: widget.session.token));
  final List<RemoteFile> _path = [];
  // Session/view-local opaque identities only; never persisted display paths.
  final List<List<String>> _listingHistory = [[]];
  int _historyIndex = 0;
  int? _resolvingIntent;
  bool get _resolvingLocation => _resolvingIntent == _navigationGeneration;

  void _rememberLocation({int? historyIndex}) {
    if (historyIndex != null) {
      _historyIndex = historyIndex;
      return;
    }
    final ids = _path.map((entry) => entry.id).toList();
    if (listEquals(ids, _listingHistory[_historyIndex])) return;
    _listingHistory.removeRange(_historyIndex + 1, _listingHistory.length);
    _listingHistory.add(List.unmodifiable(ids));
    if (_listingHistory.length > 100) _listingHistory.removeAt(0);
    _historyIndex = _listingHistory.length - 1;
  }

  Future<void> _visitLocation(List<String> ids, {int? historyIndex}) async {
    if (!mounted || widget.session.search.closed) return;
    _dismissDetails();
    final intent = _advanceNavigation();
    final generation = _refreshGeneration;
    bool current() => mounted && !widget.session.search.closed &&
        intent == _navigationGeneration && generation == _refreshGeneration;
    setState(() => _resolvingIntent = intent);
    try {
      await widget.operations.run(widget.session.handle, () async {
        final parents = <RemoteFile>[];
        final names = <String, String>{};
        String? parent;
        for (final id in ids) {
          final files = await _api.listFiles(parentId: parent);
          if (!current()) return;
          final entry = files.where((file) => file.id == id).single;
          if (!entry.isDir || entry.parentId != parent || parents.any((p) => p.id == id)) {
            throw StateError('Unavailable location');
          }
          names[id] = NativeBridge.instance.openName(
              widget.session.handle, entry.id, entry.nameEnc);
          parents.add(entry);
          parent = id;
        }
        if (!current()) return;
        setState(() {
          _path..clear()..addAll(parents);
          _names.addAll(names);
          _files = [];
          _search = '';
          _folderFilter.clear();
        });
        await _refreshNow(historyIndex: historyIndex);
      });
    } on ApiException catch (error) {
      if (!current()) return;
      if (error.status == 401) {
        widget.onSignOut();
      } else {
        _showError('Location unavailable. Refresh and retry.');
      }
    } catch (_) {
      if (current()) _showError('Location unavailable. Refresh and retry.');
    } finally {
      if (mounted && intent == _navigationGeneration) {
        setState(() => _resolvingIntent = null);
      }
    }
  }

  void _historyStep(int delta) {
    final next = _historyIndex + delta;
    if (!_browserCommandsReady || next < 0 || next >= _listingHistory.length) return;
    _visitLocation(_listingHistory[next], historyIndex: next);
  }

  ValueChanged<int>? get _breadcrumbVisitor {
    if (!_browserCommandsReady) return null;
    final generation = _refreshGeneration;
    final navigation = _navigationGeneration;
    final ids = _path.map((entry) => entry.id).toList();
    return (count) {
      if (!mounted || widget.session.search.closed || _loading ||
          generation != _refreshGeneration || navigation != _navigationGeneration) {
        return;
      }
      _visitLocation(ids.take(count).toList());
    };
  }
  List<RemoteFile> _files = [];
  final Map<String, String> _names = {};
  AccountInfo? _me;
  bool _loading = true;
  String? _error;
  String _search = '';
  BrowserView _browserView = BrowserView.list;
  BrowserSort _browserSort = BrowserSort.name;
  bool _browserDescending = false;
  BrowserListing _browserListing = BrowserListing(const [], (_) => '');
  // Original opaque models, scoped to one listing and filter; never persisted.
  final Map<String, RemoteFile> _selectedFiles = {};
  Map<String, RemoteFile> _listingFilesById = {};
  bool _selectionMode = false;
  int _selectionGeneration = 0;

  void _clearSelection({bool exit = true}) {
    if (!mounted) return;
    setState(() {
      ++_selectionGeneration;
      _selectedFiles.clear();
      if (exit) _selectionMode = false;
    });
  }

  int _advanceNavigation() {
    _clearSelection();
    return ++_navigationGeneration;
  }

  bool Function() get _selectionAdmission {
    final generation = _refreshGeneration;
    final navigation = _navigationGeneration;
    final selection = _selectionGeneration;
    return () => _browserCommandsReady && _selectionMode &&
        generation == _refreshGeneration && navigation == _navigationGeneration &&
        selection == _selectionGeneration;
  }

  ValueChanged<RemoteFile>? get _selectionCallback {
    if (!_selectionMode) return null;
    final admit = _selectionAdmission;
    return (file) {
      if (!admit() || !identical(_listingFilesById[file.id], file)) return;
      setState(() {
        if (_selectedFiles.remove(file.id) == null) _selectedFiles[file.id] = file;
      });
    };
  }

  Widget _selectionControls(List<RemoteFile> visible) {
    if (!_selectionMode) {
      final generation = _refreshGeneration;
      final navigation = _navigationGeneration;
      final selection = _selectionGeneration;
      final onSelect = _browserCommandsReady && visible.isNotEmpty ? () {
          if (!_browserCommandsReady || generation != _refreshGeneration ||
              navigation != _navigationGeneration || selection != _selectionGeneration) {
            return;
          }
          _dismissDetails();
          setState(() { ++_selectionGeneration; _selectionMode = true; });
        } : null;
      return IconButton(tooltip: 'Select items', onPressed: onSelect,
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: const Icon(Icons.checklist));
    }
    final admit = _selectionAdmission;
    final file = _selectedFiles.length == 1 ? _selectedFiles.values.single : null;
    Widget button(String label, VoidCallback action) => TextButton(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: () { if (admit()) action(); }, child: Text(label));
    return Row(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Semantics(liveRegion: true, child: Text('${_selectedFiles.length} selected'))),
      Expanded(child: Scrollbar(child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Tooltip(message: 'Select all entries in the loaded filtered folder view, not the account',
            child: button('Select all visible', () => setState(() {
              _selectedFiles..clear()..addEntries(visible.map((f) => MapEntry(f.id, f)));
            }))),
          button('Clear selection', () => _clearSelection(exit: false)),
          if (file != null) button('Selection details', () {
            if (_selectedFiles.length == 1 && identical(_selectedFiles[file.id], file)) {
              _showDetails(file);
            }
          }),
          button('Exit selection', _clearSelection),
        ]),
      ))),
    ]);
  }
  final _folderFilter = TextEditingController();
  final _folderFilterFocus = FocusNode();
  final _browserFocus = FocusNode();
  DialogRoute<String>? _commandsRoute;

  bool get _browserCommandsReady => mounted && !_loading && !_resolvingLocation && _error == null &&
      !widget.session.search.closed && ModalRoute.of(context)?.isCurrent == true;

  bool get _admitBrowserKey {
    if (!_browserCommandsReady) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused == null || (focused.widget is! EditableText &&
        focused.findAncestorWidgetOfExactType<EditableText>() == null);
  }

  List<BrowserCommand> get _browserCommands => [
    const BrowserCommand('refresh', 'Refresh folder', binding: 'F5'),
    const BrowserCommand('filter', 'Focus folder filter', binding: 'Ctrl/Cmd+Shift+F'),
    const BrowserCommand('search', 'Search all files', binding: 'Ctrl/Cmd+F'),
    const BrowserCommand('commands', 'Command palette', binding: 'Ctrl/Cmd+K'),
    const BrowserCommand('help', 'Shortcut help', binding: 'Ctrl/Cmd+/'),
    BrowserCommand('up', 'Up one folder', binding: 'Alt+Up',
        disabledReason: _path.isEmpty ? 'Already at the browser root' : null),
    BrowserCommand('back', 'Back in listing history', binding: 'Alt+Left',
        disabledReason: _historyIndex == 0 ? 'No earlier listing' : null),
    BrowserCommand('forward', 'Forward in listing history', binding: 'Alt+Right',
        disabledReason: _historyIndex + 1 == _listingHistory.length ? 'No later listing' : null),
    const BrowserCommand('global', 'Global location'),
    const BrowserCommand('devices', 'Devices location'),
    const BrowserCommand('sync', 'Sync folders'),
    const BrowserCommand('activity', 'Activity'),
    const BrowserCommand('trash', 'Trash'),
    const BrowserCommand('settings', 'Settings / account'),
  ];

  void _dismissCommands() {
    final route = _commandsRoute;
    _commandsRoute = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  void _onSearchLifecycle() {
    if (mounted && widget.session.search.closed) {
      _dismissDetails();
      setState(() {
        _advanceNavigation();
        _search = '';
        _folderFilter.clear();
        _listingHistory..clear()..add([]);
        _historyIndex = 0;
        _path.clear();
        _names.clear();
        _files = [];
        _listingFilesById = {};
        _browserListing = BrowserListing(const [], (_) => '');
      });
    }
  }

  Future<void> _showCommands({bool help = false}) async {
    if (!_browserCommandsReady) return;
    final generation = _refreshGeneration;
    final navigation = _navigationGeneration;
    final route = DialogRoute<String>(context: context,
      builder: (_) => BrowserCommandPalette(commands: _browserCommands, help: help));
    _commandsRoute = route;
    final result = await Navigator.of(context).push(route);
    if (!identical(_commandsRoute, route)) return;
    _commandsRoute = null;
    if (generation != _refreshGeneration || navigation != _navigationGeneration ||
        !_browserCommandsReady) {
      return;
    }
    _browserFocus.requestFocus();
    if (result != null) _runBrowserCommand(result);
  }

  void _runBrowserCommand(String id) {
    if (!_browserCommandsReady ||
        !_browserCommands.any((command) => command.id == id && command.disabledReason == null)) {
      return;
    }
    switch (id) {
      case 'refresh': _refresh();
      case 'filter': _folderFilterFocus.requestFocus();
      case 'search': _openAccountSearch();
      case 'commands': _showCommands();
      case 'help': _showCommands(help: true);
      case 'up': _up();
      case 'back': _historyStep(-1);
      case 'forward': _historyStep(1);
      case 'global': _selectDestination(SessionDestination.global);
      case 'devices': _selectDestination(SessionDestination.devices);
      case 'sync': _openSync();
      case 'activity': _openActivity();
      case 'trash': _openTrash();
      case 'settings': _selectDestination(SessionDestination.settings);
    }
  }

  Map<ShortcutActivator, Intent> get _browserKeys => {
    BrowserKeyActivator(LogicalKeyboardKey.escape,
      admit: () => _browserCommandsReady && _detailsPane != null):
      const BrowserCommandIntent('close-details'),
    for (final meta in [false, true]) ...{
      BrowserKeyActivator(LogicalKeyboardKey.keyK, control: !meta, meta: meta,
        admit: () => _admitBrowserKey): const BrowserCommandIntent('commands'),
      BrowserKeyActivator(LogicalKeyboardKey.slash, control: !meta, meta: meta,
        admit: () => _admitBrowserKey): const BrowserCommandIntent('help'),
      BrowserKeyActivator(LogicalKeyboardKey.keyF, control: !meta, meta: meta,
        admit: () => _admitBrowserKey): const BrowserCommandIntent('search'),
      BrowserKeyActivator(LogicalKeyboardKey.keyF, control: !meta, meta: meta, shift: true,
        admit: () => _admitBrowserKey): const BrowserCommandIntent('filter'),
    },
    BrowserKeyActivator(LogicalKeyboardKey.f5, admit: () => _admitBrowserKey):
      const BrowserCommandIntent('refresh'),
    BrowserKeyActivator(LogicalKeyboardKey.arrowUp, alt: true, admit: () => _admitBrowserKey):
      const BrowserCommandIntent('up'),
    BrowserKeyActivator(LogicalKeyboardKey.arrowLeft, alt: true, admit: () => _admitBrowserKey):
      const BrowserCommandIntent('back'),
    BrowserKeyActivator(LogicalKeyboardKey.arrowRight, alt: true, admit: () => _admitBrowserKey):
      const BrowserCommandIntent('forward'),
  };

  late final SyncController _sync;
  late final ActivityLog _activity = widget.activity ??
      ActivityLog(
        store: PreferencesActivityStore(accountId: widget.session.accountId),
        accountId: widget.session.accountId,
      );
  bool _wasSyncing = false;
  bool _syncLoaded = false;
  Map<String, LocalAvailability> _availability = {};
  int _refreshGeneration = 0;
  DialogRoute<void>? _detailsRoute;
  BrowserFileDetails? _detailsPane;
  bool _canDockDetails = false;

  void _dismissDetails() {
    if (_detailsPane != null) setState(() => _detailsPane = null);
    // Both transient browser observations share refresh/navigation invalidation.
    _dismissCommands();
    final route = _detailsRoute;
    _detailsRoute = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  ValueChanged<RemoteFile> get _detailsCallback {
    final generation = _refreshGeneration;
    final navigation = _navigationGeneration;
    return (file) {
      if (generation == _refreshGeneration && navigation == _navigationGeneration) {
        _showDetails(file);
      }
    };
  }

  void _showDetails(RemoteFile file) {
    if (!_browserCommandsReady ||
        !_files.any((entry) => identical(entry, file))) {
      return;
    }
    _dismissDetails();
    late final BrowserFileDetails details;
    details = BrowserFileDetails.observed(
      file: file,
      name: _name(file),
      availability: _availability[file.id] ?? LocalAvailability.unknown,
      pinned: _offlinePins.contains(_pinKey(file.id, file.currentVersion ?? '')),
      docked: _canDockDetails,
      onClose: _canDockDetails ? () {
        if (mounted && identical(_detailsPane, details)) _dismissDetails();
      } : null,
    );
    if (_canDockDetails) {
      setState(() => _detailsPane = details);
      return;
    }
    final route = DialogRoute<void>(context: context, builder: (_) => details);
    _detailsRoute = route;
    Navigator.of(context).push(route).whenComplete(() {
      if (identical(_detailsRoute, route)) _detailsRoute = null;
    });
  }

  Widget _detailsLayout(Widget browser) => LayoutBuilder(
    builder: (context, constraints) {
      // Use actual post-navigation space, not just the outer window width.
      final dock = MediaQuery.sizeOf(context).width >= 1200 &&
          constraints.maxWidth >= 801;
      if (_canDockDetails != dock) {
        _canDockDetails = dock;
        final pane = _detailsPane;
        final route = _detailsRoute;
        // Deliberately dismiss on a mode change, without Navigator mutations
        // during layout. Do not let an old resize callback close a new item.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if ((pane != null && identical(_detailsPane, pane)) ||
              (route != null && identical(_detailsRoute, route))) {
            _dismissDetails();
          }
        });
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: browser),
          if (dock && _detailsPane != null) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: 320, child: _detailsPane),
          ],
        ],
      );
    },
  );

  /// Opened lazily: the first listing refresh or offline action opens it, and
  /// until then no cache directory is created on a device that never uses one.
  Future<DownloadCache>? _cacheFuture;

  /// `fileId\u0000revisionId` keys that are pinned on this device. Filled best
  /// effort: a cache that cannot be read simply means no badge, never an error.
  Set<String> _offlinePins = {};

  /// The fixed space this path starts in, when it starts in one. A write inside
  /// a space whose own device is offline stays allowed, but the user is told
  /// what happens to the other device's unsynced copy.
  AccountRoot? get _currentSpace => _path.isEmpty
      ? null
      : accountRootForNodeId(_path.first.id, _sync.accountRoots);

  Future<Map<String, LocalAvailability>> _inspectAvailability(
      List<String> parentIds) async {
    try {
      final bridge = NativeBridge.instance;
      return await inspectBrowserAvailability(
        parentIds: parentIds,
        folders: List.of(_sync.folders),
        list: (parent) => _api.listFiles(parentId: parent),
        decrypt: (entry) => bridge.openName(
            widget.session.handle, entry.id, entry.nameEnc),
        comparisonKey: bridge.nameCollisionKey,
        verifyFile: _sync.fileMatches,
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _revealLocal(RemoteFile file) =>
      _fileOperation(() => _revealLocalNow(file));

  Future<void> _revealLocalNow(RemoteFile file) async {
    final parents = _path.map((entry) => entry.id).toList();
    try {
      await revealLocalAvailability(() async =>
          (await _inspectAvailability(parents))[file.id] ??
          LocalAvailability.unknown);
    } catch (_) {
      if (mounted) _showError('No safe local copy could be revealed. Refresh and check the sync folder.');
    }
    if (mounted) await _refresh();
  }

  @override
  void initState() {
    super.initState();
    _sync = widget.sync;
    _syncLoaded = _sync.loaded;
    _sync.addListener(_onSyncChanged);
    widget.session.search.addListener(_onSearchLifecycle);
    _refresh();
  }

  void _onSyncChanged() {
    if (!mounted) return;
    _dismissDetails();
    // The controller belongs to the session and loads independently of this
    // page. Reinspect availability once its configured roots have arrived.
    final justLoaded = _sync.loaded && !_syncLoaded;
    _syncLoaded = _sync.loaded;
    final active = _sync.syncing || _sync.folders.any((folder) => folder.running);
    setState(() {
      if (active) {
        _availability = _availability.map(
            (id, state) => MapEntry(id, state.withoutEquality()));
      }
    });
    if (justLoaded || (_wasSyncing && !active)) {
      _refresh();
    }
    _wasSyncing = active;
  }

  @override
  void dispose() {
    _sync.removeListener(_onSyncChanged);
    _selectedFiles.clear();
    _listingFilesById.clear();
    widget.session.search.removeListener(_onSearchLifecycle);
    final commands = _commandsRoute;
    _commandsRoute = null;
    if (commands != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (commands.isActive) commands.navigator?.removeRoute(commands);
      });
    }
    _folderFilterFocus.dispose();
    _browserFocus.dispose();
    // Home can be replaced beneath a dialog (for example on sign-out). Wait
    // until the navigator's current build/disposal lock has been released.
    final details = _detailsRoute;
    _detailsRoute = null;
    if (details != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (details.isActive) details.navigator?.removeRoute(details);
      });
    }
    _folderFilter.dispose();
    super.dispose();
  }

  void _selectDestination(SessionDestination destination) {
    // Every destination supersedes any still-resolving browser root.
    _dismissDetails();
    _advanceNavigation();
    switch (destination) {
      case SessionDestination.global:
        _openBrowserRoot(global: true);
      case SessionDestination.devices:
        _openBrowserRoot(global: false);
      case SessionDestination.sync:
        _openSync();
      case SessionDestination.activity:
        _openActivity();
      case SessionDestination.search:
        _openAccountSearch();
      case SessionDestination.trash:
        _openTrash();
      case SessionDestination.settings:
        _showAccountMenu();
      case SessionDestination.manageDevices:
        _showDevices();
    }
  }

  int _navigationGeneration = 0;

  Future<void> _openBrowserRoot({required bool global}) async {
    if (widget.session.search.closed) return;
    final intent = _navigationGeneration;
    final generation = _refreshGeneration;
    bool current() => mounted && !widget.session.search.closed &&
        intent == _navigationGeneration && generation == _refreshGeneration;
    try {
      await widget.operations.run(widget.session.handle, () async {
        RemoteFile? target;
        String? name;
        if (global) {
          final roots = await _api.listRoots();
          if (!current()) return;
          final root = roots.where((root) => root.isGlobal).single;
          final files = await _api.listFiles();
          if (!current()) return;
          target = files.where((file) => file.id == root.nodeId &&
              file.parentId == null && file.isDir).single;
          name = NativeBridge.instance.openName(
              widget.session.handle, target.id, target.nameEnc);
        }
        if (!current()) return;
        final selectedTarget = target;
        setState(() {
          _path.clear();
          if (selectedTarget != null) {
            _path.add(selectedTarget);
            _names[selectedTarget.id] = name!;
          }
          _files = [];
          _search = '';
          _folderFilter.clear();
        });
        await _refreshNow();
      });
    } on ApiException catch (e) {
      if (!current()) return;
      if (e.status == 401) {
        widget.onSignOut();
      } else {
        _showError('Location unavailable. Refresh and retry.');
      }
    } catch (_) {
      if (current()) {
        _showError('Location unavailable. Refresh and retry.');
      }
    }
  }

  Future<void> _openAccountSearch() async {
    _dismissDetails();
    _advanceNavigation();
    final index = widget.session.search;
    final entry = await Navigator.of(context).push<SearchEntry>(MaterialPageRoute(
      builder: (_) => AccountSearchPage(index: index,
        inspectStatuses: (snapshot, cancelled) async {
          if (!_sync.loaded) return {};
          return inspectSearchStatuses(snapshot: snapshot,
            folders: _sync.folders,
            cancelled: cancelled);
        }),
    ));
    if (entry != null) await _navigateIndexedEntry(entry, containingOnly: false);
  }

  Future<void> _navigateIndexedEntry(SearchEntry entry, {required bool containingOnly}) async {
    final index = widget.session.search;
    if (!mounted || index.closed) return;
    final intent = _advanceNavigation();
    bool current() => mounted && !index.closed && intent == _navigationGeneration;
    try {
      await widget.operations.run(widget.session.handle, () async {
        final parents = await resolveSearchLocation(index: index, entry: entry,
          containingOnly: containingOnly,
          list: (parent) => _api.listFiles(parentId: parent),
          decrypt: (files) async {
            final names = await NativeBridge.instance.openNamesAsync(
              widget.session.handle,
              files.map((file) => (id: file.id, nameEnc: file.nameEnc)).toList());
            return {for (var i = 0; i < files.length; i++) files[i].id: names[i]};
          });
        if (!current()) return;
        setState(() {
          _search = '';
          _folderFilter.clear();
          _path..clear()..addAll(parents.map((e) => e.file));
          _names.addAll({for (final parent in parents) parent.file.id: parent.name});
          _files = [];
        });
        await _refreshNow();
        if (!current() || _error != null || containingOnly || entry.file.isDir) return;
        final selected = _files.where((file) => file.id == entry.file.id).firstOrNull;
        if (selected != null) _open(selected);
      });
    } on ApiException catch (error) {
      if (!current()) return;
      if (error.status == 401) {
        widget.onSignOut();
      } else {
        _showError('Folder unavailable. Refresh the source page and retry.');
      }
    } catch (_) {
      if (current()) {
        _showError('Folder unavailable. Refresh the source page and retry.');
      }
    }
  }

  /// Local folder name used by activity rows for actions in this view.
  String get _activityFolder => _path.isEmpty ? 'My files' : _name(_path.last);

  void _recordActivity(ActivityKind kind, String subject,
      {String? itemId, int? size, String? reason}) {
    _activity.record(
      kind: kind,
      folder: _activityFolder,
      subject: subject,
      itemId: itemId,
      size: size,
      reason: reason,
    );
  }

  Future<void> _openActivity() async {
    _dismissDetails();
    _advanceNavigation();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ActivityPage(
        log: _activity,
        onShowUnsynced: _showUnsynced,
      ),
    ));
  }

  /// Opens the Not synced screen for the folder an activity row names.
  ///
  /// The feed is closed first so Back returns to the files, not to the feed.
  Future<void> _showUnsynced(ActivityEntry entry) async {
    final rootId = entry.folderRootId;
    if (rootId == null || !mounted) return;
    Navigator.of(context).pop();
    await _openSync(openOverviewFor: rootId);
  }

  Future<void> _openSync({String? openOverviewFor}) async {
    _dismissDetails();
    _advanceNavigation();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) =>
          SyncPage(controller: _sync, openOverviewFor: openOverviewFor),
    ));
    if (mounted) _refresh();
  }

  Future<void> _openTrash() async {
    _dismissDetails();
    _advanceNavigation();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TrashPage(
        load: _api.trash,
        decrypt: _decryptTrashNames,
        restore: (id, {String? parentId, bool toRoot = false}) =>
            widget.operations.run(widget.session.handle,
                () => _api.restoreFile(id, parentId: parentId, toRoot: toRoot)),
        purge: (id) =>
            widget.operations.run(widget.session.handle, () => _api.purgeFile(id)),
        emptyTrash: () => widget.operations
            .run(widget.session.handle, () => _api.emptyTrash()),
        previewRewind: (before, {String? scopeId, String? after}) =>
            widget.operations.run(
                widget.session.handle,
                () => _api.rewindPreview(
                    before: before, scopeId: scopeId, after: after)),
        applyRewind: (before, items, {String? scopeId}) =>
            widget.operations.run(widget.session.handle,
                () => _api.rewind(
                    before: before, items: items, scopeId: scopeId)),
        decryptRewind: _decryptRewindNames,
        pickFolder: _pickFolder,
      ),
    ));
    if (mounted) _refresh();
  }

  /// Opens the shared folder chooser for a restore destination or a rewind
  /// scope. It lists fresh remote folders and returns IDs plus local names only.
  Future<FolderChoice?> _pickFolder() => showDialog<FolderChoice>(
        context: context,
        builder: (_) => FolderPickerDialog(
          api: _api,
          handle: widget.session.handle,
          operations: widget.operations,
          title: 'Choose a folder',
          confirmLabel: 'Use this folder',
        ),
      );

  /// Opens the sealed names of rewind rows the same way as trash names.
  Future<List<String>> _decryptRewindNames(List<RewindItem> items) async {
    final bridge = NativeBridge.instance;
    final handle = widget.session.handle;
    final names = <String>[];
    for (var start = 0; start < items.length; start += 128) {
      final batch = items
          .skip(start)
          .take(128)
          .map((item) => (id: item.id, nameEnc: item.nameEnc))
          .toList();
      try {
        names.addAll(await bridge.openNamesAsync(handle, batch));
      } catch (_) {
        names.addAll(batch.map((_) => 'Name unavailable'));
      }
    }
    return names;
  }

  /// Opens sealed trash names in bounded batches through the session-owned
  /// native runner, so nothing blocks the UI isolate for long.
  Future<List<String>> _decryptTrashNames(List<TrashEntry> entries) async {
    final bridge = NativeBridge.instance;
    final handle = widget.session.handle;
    final names = <String>[];
    for (var start = 0; start < entries.length; start += 128) {
      final batch = entries
          .skip(start)
          .take(128)
          .map((entry) => (id: entry.id, nameEnc: entry.nameEnc))
          .toList();
      names.addAll(await bridge.openNamesAsync(handle, batch));
    }
    return names;
  }

  Future<void> _refresh() => _fileOperation(_refreshNow);

  Future<void> _refreshNow({int? historyIndex}) async {
    _dismissDetails();
    _clearSelection();
    final generation = ++_refreshGeneration;
    final navigation = _navigationGeneration;
    bool current() => mounted && !widget.session.search.closed &&
        generation == _refreshGeneration && navigation == _navigationGeneration;
    final parentIds = _path.map((entry) => entry.id).toList();
    setState(() {
      _loading = true;
      _availability = {};
      _error = null;
    });
    try {
      final me = await _api.me();
      if (!current()) return;
      if (_sync.loaded && _sync.accountRoots.isNotEmpty) {
        await _sync.refreshAccountRoots();
      }
      if (!current()) return;
      final files = await _api.listFiles(parentId: parentIds.lastOrNull);
      if (!current()) return;
      final bridge = NativeBridge.instance;
      final names = <String, String>{};
      for (final f in files) {
        try {
          names[f.id] = bridge.openName(widget.session.handle, f.id, f.nameEnc);
        } catch (_) {
          names[f.id] = f.isDir ? 'Encrypted folder' : 'Encrypted file';
        }
      }
      await _sync.scanConflicts();
      final availability = await _inspectAvailability(parentIds);
      if (!current()) return;
      setState(() {
        _availability = availability;
        _me = me;
        _files = files;
        _listingFilesById = {for (final file in files) file.id: file};
        // Keep the folders on the trail named: the app-bar title and up control
        // read from here, and a listing only carries the current folder's
        // entries. Drop names for anything no longer on screen or on the trail.
        final keep = {for (final entry in _path) entry.id, ...names.keys};
        _names
          ..removeWhere((id, _) => !keep.contains(id))
          ..addAll(names);
        for (final root in _sync.accountRoots) {
          if (keep.contains(root.nodeId)) _names[root.nodeId] = accountRootLabel(root);
        }
        _browserListing = BrowserListing(_files, _name);
        _rememberLocation(historyIndex: historyIndex);
      });
    } on ApiException catch (e) {
      if (!current()) return;
      if (e.status == 401) {
        widget.onSignOut();
        return;
      }
      if (mounted) {
        setState(() => _error = 'Folder unavailable. Refresh and retry.');
      }
    } catch (e) {
      if (current()) {
        setState(() => _error = 'Folder unavailable. Refresh and retry.');
      }
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _loading = false);
        unawaited(_refreshOfflinePins());
      }
    }
  }

  void _open(RemoteFile file) {
    if (!mounted || _loading || widget.session.search.closed ||
        !_files.any((entry) => identical(entry, file))) {
      return;
    }
    if (file.isDir) {
      _visitLocation([..._path.map((entry) => entry.id), file.id]);
      return;
    }
    _itemActions(file);
  }

  /// Leaves one folder. Android system back and the app-bar up control share
  /// this, so back cannot drop the user out of the account while a folder is
  /// open.
  void _up() {
    if (_path.isEmpty || widget.session.search.closed) return;
    _visitLocation(_path.take(_path.length - 1).map((entry) => entry.id).toList());
  }

  /// Keeps Android back inside the folder trail. The route itself stays
  /// poppable only at the account root, so back then exits the app normally.
  Widget _backScope(Widget child) => PopScope(
        canPop: _path.isEmpty && _detailsPane == null && !_selectionMode,
        onPopInvokedWithResult: (didPop, Object? result) {
          if (didPop) return;
          if (_detailsPane != null) {
            _dismissDetails();
          } else if (_selectionMode) {
            _clearSelection();
          } else {
            _up();
          }
        },
        child: child,
      );

  String _name(RemoteFile f) => _names[f.id] ?? (f.isDir ? 'Encrypted folder' : 'Encrypted file');

  /// The fixed account space this view is inside, or null at the account root.
  /// The folder trail starts at a top-level entry, which is how a space is
  /// entered, so its first element identifies the space when it is one.
  String? get _sourceSpaceRootId => _path.isEmpty ? null : _path.first.id;

  bool _renaming = false;

  Future<void> _copy(RemoteFile file) async {
    if (_renaming) return;
    setState(() => _renaming = true);
    try {
      final destination = await showDialog<MoveDestination>(context: context,
        builder: (_) => MoveDialog(api: _api, handle: widget.session.handle,
          operations: widget.operations, source: file, copy: true,
          sourceSpaceRootId: _sourceSpaceRootId));
      if (destination == null || !mounted) return;
      final attempted = await showDialog<bool>(context: context,
        barrierDismissible: false,
        builder: (_) => CopyFileDialog(isDir: file.isDir,
          onConfirmed: () => _recordActivity(ActivityKind.copied, _name(file),
            itemId: file.id, size: file.size),
          runCopy: () => widget.operations.run(widget.session.handle,
            () => copyRemoteFile(api: _api, handle: widget.session.handle,
              file: file, parentId: destination.parentId))));
      if (attempted == true && mounted) await _refresh();
    } catch (_) {
      if (mounted) _showError('Copy was not confirmed. Refresh the destination before starting another copy.');
    } finally {
      if (mounted) setState(() => _renaming = false);
    }
  }

  Future<void> _move(RemoteFile file) async {
    if (_renaming) return;
    setState(() => _renaming = true);
    MoveDestination? destination;
    try {
      destination = await showDialog<MoveDestination>(context: context,
        builder: (_) => MoveDialog(api: _api, handle: widget.session.handle,
          operations: widget.operations, source: file,
          sourceSpaceRootId: _sourceSpaceRootId));
      if (destination == null || !mounted) return;
      await widget.operations.run(widget.session.handle, () =>
        moveRemoteEntry(api: _api, handle: widget.session.handle,
          file: file, parentId: destination!.parentId));
      _recordActivity(ActivityKind.moved, _name(file),
          itemId: file.id, size: file.size);
      if (mounted) await _refresh();
    } on RenameFailure catch (e) {
      if (mounted) _showError(e.message);
    } on ApiException catch (e) {
      if (e.status == 0 && destination != null) {
        // Unreachable server: keep the intent on this device instead of losing
        // it. The replay re-checks both ends, so a later conflict stops safely.
        final message =
            await widget.sync.enqueueOfflineMove(file, destination.parentId);
        if (!mounted) return;
        _toast(message);
      } else if (mounted) {
        _showError('Move failed. Refresh and try again. Choose a different destination if it is inside the source folder.');
      }
    } catch (_) {
      if (mounted) _showError('Move failed. Refresh and try again. Choose a different destination if it is inside the source folder.');
    } finally {
      if (mounted) setState(() => _renaming = false);
    }
  }

  Future<void> _rename(RemoteFile file) async {
    if (_renaming) return;
    setState(() => _renaming = true);
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (_) => RenameDialog(initialName: _name(file), isDir: file.isDir),
      );
      if (name == null || !mounted) return;
      final root = accountRootForNodeId(file.id, _sync.accountRoots);
      if (root != null && !root.isGlobal) {
        final invalid = deviceNameValidationError(name);
        if (invalid != null) throw RenameFailure(invalid);
      }
      await widget.operations.run(widget.session.handle, () =>
        renameRemoteEntry(api: _api, handle: widget.session.handle,
          file: file, name: name));
      _recordActivity(ActivityKind.renamed, '${_name(file)} → $name',
          itemId: file.id);
      if (mounted) await _refresh();
    } on RenameFailure catch (e) {
      if (mounted) _showError(e.message);
    } catch (_) {
      // Do not expose backend/native diagnostics that could contain secrets.
      if (mounted) _showError('Rename failed. Refresh and try again. Check for a name collision or an entry changed on another device.');
    } finally {
      if (mounted) setState(() => _renaming = false);
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => DiscardOnBack(
        hasUnsavedInput: () => controller.text.trim().isNotEmpty,
        child: AlertDialog(
          title: const Text('New folder'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Folder name'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return;
    await _fileOperation(() => _createFolderNamed(name));
  }

  Future<void> _fileOperation(Future<void> Function() action) async {
    try {
      await widget.operations.run(widget.session.handle, action);
    } catch (e) { if (mounted) _showError(e); }
  }

  Future<void> _createFolderNamed(String name) async {
    if (!_sync.deviceNameConfirmed) return;
    final id = _uuid.v4();
    try {
      final sealed = NativeBridge.instance.sealName(widget.session.handle, id, name);
      await _api.createFile(
        id: id,
        parentId: _path.isEmpty ? _requiredDeviceRoot() : _path.last.id,
        nameEnc: sealed,
        isDir: true,
      );
      await _refresh();
    } catch (e) {
      _showError(e);
    }
  }

  String _requiredDeviceRoot() {
    final root = _sync.deviceRootNodeId;
    if (!_sync.deviceNameConfirmed || root == null || _sync.rootsError != null) {
      throw StateError('Initialize and confirm this device space before uploading.');
    }
    return root;
  }

  Future<void> _upload() async {
    if (!_sync.deviceNameConfirmed) return;
    const group = XTypeGroup(label: 'All files');
    final picked = await openFile(acceptedTypeGroups: const [group]);
    if (picked == null) return;
    await _fileOperation(() => _uploadPicked(picked.path));
  }

  Future<void> _uploadPicked(String path) async {
    if (!_sync.deviceNameConfirmed) return;
    final name = p.basename(path);
    final fileId = _uuid.v4();
    final revisionId = _uuid.v4();
    try {
      final sealed = NativeBridge.instance.sealName(widget.session.handle, fileId, name);
      await _api.createFile(
        id: fileId,
        parentId: _path.isEmpty ? _requiredDeviceRoot() : _path.last.id,
        nameEnc: sealed,
        isDir: false,
      );
      _showProgress('Encrypting and uploading $name');
      final result = await widget.session.upload(
        fileId: fileId,
        revisionId: revisionId,
        parentRevision: '',
        path: path,
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _recordActivity(ActivityKind.uploaded, name,
          itemId: fileId,
          size: result['size'] is int ? result['size'] as int : null);
      await _refresh();
      _toast('Uploaded $name — ${result['chunks_new']} new chunk(s), '
          '${result['chunks_reused']} reused, ${result['articles_posted']} article(s).');
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      try {
        await _api.deleteFile(fileId);
      } catch (_) {}
      _showError(e);
    }
  }

  Future<void> _uploadRevision(RemoteFile file) async {
    const group = XTypeGroup(label: 'All files');
    final picked = await openFile(acceptedTypeGroups: const [group]);
    if (picked == null) return;
    await _fileOperation(() => _uploadRevisionPicked(file, picked.path));
  }

  Future<void> _uploadRevisionPicked(RemoteFile file, String path) async {
    if (!_sync.deviceNameConfirmed) return;
    final revisionId = _uuid.v4();
    _showProgress('Uploading a new version of ${_name(file)}');
    try {
      final result = await widget.session.upload(
        fileId: file.id,
        revisionId: revisionId,
        parentRevision: file.currentVersion ?? '',
        path: path,
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _recordActivity(ActivityKind.uploaded, '${_name(file)} (new version)',
          itemId: file.id,
          size: result['size'] is int ? result['size'] as int : null);
      await _refresh();
      _toast('New version uploaded (${result['size']} bytes, '
          '${result['chunks_new']} new chunks, ${result['chunks_reused']} reused).');
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showError(e);
    }
  }

  Future<void> _download(RemoteFile file, {String? revisionId, String? asName}) async {
    final name = asName ?? _name(file);
    String destination;
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      destination = p.join(dir.path, name);
    } else {
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return;
      destination = location.path;
    }
    await _fileOperation(() => _downloadTo(file, destination, revisionId));
  }

  /// Shows a file inside the app when it is an image or plain text.
  ///
  /// A device copy is used first, so a pinned file previews without the
  /// network. Preview bytes stay in memory, and the loader deletes its scratch
  /// copy before the preview renders.
  Future<void> _preview(RemoteFile file) async {
    final revision = file.currentVersion ?? '';
    DownloadCache? cache;
    try {
      cache = await _openCache();
    } catch (_) {
      // No cache on this device: the preview falls back to a download.
      cache = null;
    }
    Directory tempRoot;
    try {
      final support = await getApplicationSupportDirectory();
      tempRoot = Directory(p.join(support.path, 'preview-tmp'));
    } catch (e) {
      _showError('Preview is unavailable on this device: $e');
      return;
    }
    if (!mounted) return;
    final loader = PreviewLoader(
      tempRoot: tempRoot,
      lookupOfflineCopy: (fileId, revisionId) {
        final local = cache?.localFile(fileId, revisionId);
        // A preview counts as a use of the offline copy, so it keeps its place
        // in the cache's least-recently-used order.
        if (local != null) unawaited(cache!.touch(fileId, revisionId));
        return local;
      },
      download: (destination) async {
        await NativeBridge.instance.downloadAsync(
          handle: widget.session.handle,
          baseUrl: widget.session.server,
          token: widget.session.token,
          fileId: file.id,
          revisionId: revision,
          destination: destination,
        );
      },
    );
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (routeContext) => PreviewPage(
        title: _name(file),
        load: () => loader.load(
          fileId: file.id,
          revisionId: revision,
          name: _name(file),
          sizeBytes: file.size,
        ),
        onDownload: () {
          Navigator.of(routeContext).pop();
          _download(file);
        },
      ),
    ));
  }

  /// Opens (and memoizes) the device cache. A failure is not memoized, so a
  /// later attempt can succeed once the directory is writable again.
  Future<DownloadCache> _openCache() => _cacheFuture ??= _openCacheNow();

  Future<DownloadCache> _openCacheNow() async {
    try {
      final support = await getApplicationSupportDirectory();
      // The limit is device-local and survives restarts; an unreadable or
      // out-of-range stored value falls back to the built-in default.
      final limit = await loadCacheLimitBytes(
        await SharedPreferences.getInstance(),
      );
      final cache = DownloadCache(
        root: Directory(p.join(support.path, 'download-cache')),
        limitBytes: limit,
      );
      await cache.open();
      return cache;
    } catch (_) {
      _cacheFuture = null;
      rethrow;
    }
  }

  static String _pinKey(String fileId, String revisionId) =>
      '$fileId\u0000$revisionId';

  /// Reads the pinned revisions so the browser can badge them. Silent on
  /// failure: offline copies are an enhancement, not a browsing prerequisite.
  Future<void> _refreshOfflinePins() async {
    try {
      final cache = await _openCache();
      final pins = {
        for (final entry in cache.entries)
          if (entry.pinned) _pinKey(entry.fileId, entry.revisionId)
      };
      if (mounted && !setEquals(pins, _offlinePins)) {
        setState(() => _offlinePins = pins);
      }
    } catch (_) {
      // No cache on this device/build: leave the badges off.
    }
  }

  Future<void> _openCachePage() async {
    DownloadCache cache;
    try {
      cache = await _openCache();
    } catch (e) {
      _showError('The offline cache is unavailable on this device: $e');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DownloadCachePage(
        cache: cache,
        nameFor: (id) => _names[id] ?? '',
        onChanged: () {
          if (mounted) unawaited(_refreshOfflinePins());
        },
        onLimitChanged: (bytes) async {
          try {
            return await saveCacheLimitBytes(
              await SharedPreferences.getInstance(),
              bytes,
            );
          } catch (_) {
            return false;
          }
        },
      ),
    ));
  }

  /// Keeps one file on this device so it opens without the network, or removes
  /// that copy. Only the cache directory is touched; sync folders and saved
  /// files are never involved.
  Future<void> _keepOffline(RemoteFile file) async {
    if (file.isDir) return;
    final revision = file.currentVersion ?? '';
    final DownloadCache cache;
    try {
      cache = await _openCache();
    } catch (e) {
      _showError('The offline cache is unavailable on this device: $e');
      return;
    }
    if (!mounted) return;
    final existing = cache.find(file.id, revisionId: revision);
    if (existing != null && existing.pinned) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove the offline copy?'),
          content: Text(
              '${_name(file)} stays in your account. Only this device\'s copy '
              'is deleted, so opening it again needs the network.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await _fileOperation(() async {
        await cache.remove(file.id, revision);
      });
      if (mounted) {
        unawaited(_refreshOfflinePins());
        _toast('Removed the offline copy of ${_name(file)}.');
      }
      return;
    }
    if (existing != null) {
      // The bytes are already on this device; pinning them costs no network.
      await _fileOperation(() => cache.setPinned(file.id, revision, true));
      if (mounted) {
        unawaited(_refreshOfflinePins());
        _toast('${_name(file)} is now kept offline; it was already cached.');
      }
      return;
    }
    await _fileOperation(() => _downloadIntoCache(cache, file, revision));
  }

  /// Downloads one revision straight into the cache and pins it.
  Future<void> _downloadIntoCache(
      DownloadCache cache, RemoteFile file, String revision) async {
    _showProgress('Keeping ${_name(file)} offline');
    final partial = File(p.join(cache.root.path, '${_uuid.v4()}.part'));
    try {
      await cache.root.create(recursive: true);
      await NativeBridge.instance.downloadAsync(
        handle: widget.session.handle,
        baseUrl: widget.session.server,
        token: widget.session.token,
        fileId: file.id,
        revisionId: revision,
        destination: partial.path,
      );
      final entry = await cache.adopt(
        fileId: file.id,
        revisionId: revision,
        source: partial,
        pinned: true,
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _recordActivity(ActivityKind.downloaded, _name(file),
          itemId: file.id,
          size: entry.sizeBytes,
          reason: 'Kept offline on this device.');
      if (mounted) {
        unawaited(_refreshOfflinePins());
        _toast('${_name(file)} is kept offline '
            '(${formatCacheBytes(entry.sizeBytes)}).');
      }
    } catch (e) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {
        // A scratch file that cannot be cleaned up is discarded on next open.
      }
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) _showError(e);
    }
  }

  Future<void> _downloadTo(RemoteFile file, String destination, String? revisionId) async {
    final wantedRevision = revisionId ?? file.currentVersion ?? '';
    try {
      final cache = await _openCache();
      final entry = cache.find(file.id, revisionId: wantedRevision);
      final local = cache.localFile(file.id, wantedRevision);
      if (entry != null && entry.pinned && local != null) {
        await local.copy(destination);
        await cache.touch(file.id, wantedRevision);
        _recordActivity(ActivityKind.downloaded, _name(file),
            itemId: file.id,
            size: entry.sizeBytes,
            reason: 'Copied from the offline copy; no network used.');
        if (mounted) {
          _toast('Saved from the offline copy '
              '(${formatCacheBytes(entry.sizeBytes)}); no network used.');
        }
        return;
      }
    } catch (_) {
      // A cache problem must never stop an ordinary verified download.
    }
    _showProgress('Downloading and verifying ${_name(file)}');
    try {
      final result = await NativeBridge.instance.downloadAsync(
        handle: widget.session.handle,
        baseUrl: widget.session.server,
        token: widget.session.token,
        fileId: file.id,
        revisionId: revisionId ?? file.currentVersion ?? '',
        destination: destination,
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _recordActivity(ActivityKind.downloaded, _name(file),
          itemId: file.id,
          size: result['size'] is int ? result['size'] as int : null);
      _toast('Saved to $destination (${result['size']} bytes, '
          '${result['shards_fetched']} shards).');
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showError(e);
    }
  }

  Future<void> _showVersions(RemoteFile file) async {
    var restored = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => VersionHistoryDialog(
        title: _name(file),
        currentVersion: file.currentVersion,
        load: () => _api.versions(file.id),
        restore: (version) async {
          // The server re-checks that this revision belongs to the file; the
          // history itself keeps every version, so this is reversible.
          await _api.restoreVersion(file.id, version.revisionId);
          restored = true;
        },
        download: (version) {
          Navigator.pop(dialogContext);
          _download(
            file,
            revisionId: version.revisionId,
            asName: '${p.basenameWithoutExtension(_name(file))} '
                '(${formatVersionTime(version.createdAt)})'
                '${p.extension(_name(file))}',
          );
        },
      ),
    );
    if (restored && mounted) {
      // The file's current content, size and revision changed.
      await _refresh();
    }
  }

  /// One menu for files and folders, used by the row overflow control and by
  /// tapping a file. Unavailable entries carry their reason instead of looking
  /// like a broken control.
  void _itemActions(RemoteFile file) {
    // Pin state comes from the badge set the refresh already loaded, so opening
    // the menu never waits on the cache; the action itself re-checks the cache
    // before it removes or adds a copy.
    final pinned = !file.isDir &&
        _offlinePins.contains(_pinKey(file.id, file.currentVersion ?? ''));
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => ItemActionsSheet(
        title: _name(file),
        details: file.isDir
            ? 'Folder'
            : '${_formatBytes(file.size)} · revision ${file.revision}',
        specs: itemActionSpecs(
          isDir: file.isDir,
          favorite: file.favorite,
          busy: _renaming,
          pinned: pinned,
        ),
        onSelected: (kind) {
          Navigator.pop(sheetContext);
          _runItemAction(file, kind);
        },
      ),
    );
  }

  Future<void> _runItemAction(RemoteFile file, ItemActionKind kind) async {
    switch (kind) {
      case ItemActionKind.open:
        _open(file);
        return;
      case ItemActionKind.preview:
        return _preview(file);
      case ItemActionKind.download:
        return _download(file);
      case ItemActionKind.keepOffline:
        return _keepOffline(file);
      case ItemActionKind.versions:
        return _showVersions(file);
      case ItemActionKind.uploadVersion:
        return _uploadRevision(file);
      case ItemActionKind.favorite:
        try {
          await _api.setFavorite(file.id, !file.favorite);
          await _refresh();
        } catch (e) {
          _showError(e);
        }
        return;
      case ItemActionKind.rename:
        return _rename(file);
      case ItemActionKind.move:
        return _move(file);
      case ItemActionKind.copy:
        return _copy(file);
      case ItemActionKind.delete:
        return _confirmDelete(file);
    }
  }

  /// Deleting is recoverable from the trash, but it always asks first.
  Future<void> _confirmDelete(RemoteFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(file.isDir ? 'Delete folder?' : 'Delete file?'),
        content: Text(
            'It moves to the Trash with everything inside it and can be '
            'restored from there while the retention window lasts. '
            '${file.isDir ? '' : 'Posted Usenet articles cannot be physically deleted.'}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.deleteFile(file.id);
      _recordActivity(ActivityKind.deleted, _name(file),
          itemId: file.id, size: file.size,
          reason: 'Moved to the Trash; restorable while retention lasts.');
      await _refresh();
    } catch (e) {
      _showError(e);
    }
  }

  void _showProgress(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 18),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString()), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _checkForUpdates() => widget.updates.manual(_checkForUpdatesNow);

  Future<void> _checkForUpdatesNow() async {
    if (Platform.isAndroid) return _checkForAndroidUpdateNow();
    if (!Updater.supported) {
      _toast('Automatic updates are available on Windows and Linux.');
      return;
    }
    _showProgress('Checking for updates…');
    try {
      final updater = Updater(await Updater.loadConfig());
      final info = await updater.check();
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (!mounted) return;
      if (info == null) {
        final version = await updater.currentVersion();
        _toast('NNTDrive $version is up to date.');
        return;
      }
      await _promptUpdate(info);
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showError(e);
    }
  }

  Future<void> _promptUpdate(UpdateInfo info) =>
      promptUpdate(context, info, _formatBytes(info.size));

  /// Android reads the same release feed but installs through the system
  /// package installer, so it uses its own check, deferral and prompt flow.
  Future<void> _checkForAndroidUpdateNow() async {
    _showProgress('Checking for updates…');
    try {
      final updater = AndroidUpdater(config: await Updater.loadConfig());
      final info = await updater.check();
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (!mounted) return;
      if (info == null) {
        _toast('NNTDrive ${await _androidVersionLabel()} is up to date.');
        return;
      }
      await promptAndroidUpdate(context, updater, info, _formatBytes(info.size));
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showError(e);
    }
  }

  Future<String> _androidVersionLabel() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '';
    }
  }

  Future<void> _showUpdateSettings() =>
      widget.updates.manual(_showUpdateSettingsNow);

  Future<void> _showUpdateSettingsNow() async {
    final config = await Updater.loadConfig();
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final repo = TextEditingController(text: config.repo);
    final token = TextEditingController(text: config.token);
    var autoCheck = prefs.getBool('updateAutoCheck') ?? true;
    var testing = false;
    var testMessage = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Update settings'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: repo,
                  decoration: const InputDecoration(
                    labelText: 'GitHub repository',
                    hintText: 'owner/repo',
                    helperText: 'Releases are read from this repository.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: token,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Access token (optional)',
                    helperText: 'Needed only while the repository is private. '
                        'Use a read-only, fine-grained token.',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: autoCheck,
                  onChanged: (value) => setDialogState(() => autoCheck = value),
                  title: const Text('Check at startup and daily'),
                ),
                const Text(
                  'The token is stored in this app’s local settings. Use a '
                  'read-only, fine-grained token with access only to the release '
                  'repository, and remove it once the repository is public.',
                  style: TextStyle(fontSize: 12),
                ),
                if (testMessage.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(testMessage, style: const TextStyle(fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: testing
                  ? null
                  : () async {
                      setDialogState(() {
                        testing = true;
                        testMessage = 'Checking access…';
                      });
                      try {
                        final updater = Updater(UpdateConfig(
                          repo: repo.text.trim(),
                          token: token.text.trim(),
                        ));
                        final info = await updater.check();
                        if (!context.mounted) return;
                        setDialogState(() {
                          testing = false;
                          testMessage = info == null
                              ? 'Access OK — you are on the latest release.'
                              : 'Access OK — version ${info.version} is available.';
                        });
                      } catch (e) {
                        if (!context.mounted) return;
                        setDialogState(() {
                          testing = false;
                          testMessage = e.toString();
                        });
                      }
                    },
              child: Text(testing ? 'Testing…' : 'Test access'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final repoText = repo.text;
    final tokenText = token.text;
    repo.dispose();
    token.dispose();
    if (saved != true) return;
    try {
      await Updater.saveConfig(
        repo: repoText,
        token: tokenText,
        autoCheck: autoCheck,
      );
      if (mounted) _toast('Update settings saved.');
    } catch (e) {
      _showError('Could not save update settings: $e');
    }
  }

  Future<void> _showAccountMenu() async {
    _dismissDetails();
    _advanceNavigation();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(widget.session.email),
              subtitle: Text('Account ${widget.session.accountId}'),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server'),
              subtitle: Text(widget.session.server),
            ),
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: const Text('Devices'),
              onTap: () {
                Navigator.pop(context);
                _showDevices();
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications_none),
              title: const Text('Activity'),
              subtitle: Text(_activity.notificationCount == 0
                  ? 'Recent actions; nothing needs attention'
                  : '${_activity.notificationCount} need attention'),
              onTap: () {
                Navigator.pop(context);
                _openActivity();
              },
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Sync folders'),
              subtitle: Text(
                _sync.folders.isEmpty
                    ? 'No folders selected'
                    : '${_sync.folders.length} folder(s)${_sync.paused ? ' · paused' : ''}'
                        '${_sync.conflictCount > 0 ? ' · ${_sync.conflictCount} conflict(s)' : ''}',
              ),
              onTap: () {
                Navigator.pop(context);
                _openSync();
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Prepare legacy references'),
              subtitle: const Text(
                  'Explicit account-scoped batches before admin cleanup'),
              onTap: () {
                Navigator.pop(context);
                showDialog<void>(
                  context: this.context,
                  barrierDismissible: false,
                  builder: (_) => ReferenceBackfillDialog(
                    runBatch: () => widget.operations.run(widget.session.handle,
                      () => NativeBridge.instance.backfillReferencesAsync(
                        widget.session.handle,
                        widget.session.server,
                        widget.session.token,
                      )),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.storage),
              title: const Text('Storage usage'),
              subtitle: const Text('Live-file totals and device cache cleanup'),
              onTap: () async {
                Navigator.pop(context);
                final entry = await Navigator.of(this.context).push<SearchEntry>(MaterialPageRoute(
                  builder: (_) => StorageUsagePage(
                    index: widget.session.search,
                    readCacheUsage: () async {
                      // Never lazily open here: open() reconciles/deletes scratch.
                      final opened = _cacheFuture;
                      if (opened == null) {
                        throw StateError('Cache accounting unavailable');
                      }
                      return (await opened).measureUsage();
                    },
                    reviewCacheDuplicates: () => widget.operations.run(
                      widget.session.handle, () async {
                        final opened = _cacheFuture;
                        if (opened == null || widget.session.search.closed) {
                          throw StateError('Cache review unavailable');
                        }
                        final cache = await opened;
                        if (widget.session.search.closed) throw StateError('Session closed');
                        final result = await _sync.reviewCacheDuplicates(cache);
                        if (widget.session.search.closed) throw StateError('Session closed');
                        return result;
                      }),
                    readSyncUsage: () => widget.operations.run(
                      widget.session.handle, () async {
                        if (widget.session.search.closed) throw StateError('Session closed');
                        final usage = await _sync.measureSyncDiskUsage();
                        if (widget.session.search.closed) throw StateError('Session closed');
                        return usage;
                      }),
                    clearUnpinnedCache: () => widget.operations.run(
                      widget.session.handle, () async {
                        final opened = _cacheFuture;
                        if (opened == null || widget.session.search.closed) {
                          throw StateError('Cache cleanup unavailable');
                        }
                        final cache = await opened;
                        if (widget.session.search.closed) {
                          throw StateError('Session closed');
                        }
                        return cache.clearUnpinned();
                      }),
                  )));
                if (entry != null) await _navigateIndexedEntry(entry, containingOnly: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.offline_pin_outlined),
              title: const Text('Offline copies & cache'),
              subtitle: const Text(
                  'What this device keeps for opening files without the network'),
              onTap: () {
                Navigator.pop(context);
                _openCachePage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Update settings'),
              subtitle: const Text('Repository and access token'),
              onTap: () {
                Navigator.pop(context);
                _showUpdateSettings();
              },
            ),
            if (Platform.isWindows || Platform.isLinux)
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Start when I sign in'),
                subtitle: Text(widget.loginAutostartError ??
                    (widget.loginAutostartEnabled
                        ? 'On — starts locked; your password is still required'
                        : 'Off — you open NNTDrive yourself')),
                onTap: () async {
                  final enable = !widget.loginAutostartEnabled;
                  Navigator.pop(context);
                  final failure =
                      await widget.onSetLoginAutostart?.call(enable);
                  if (!mounted) return;
                  if (failure == null) {
                    _toast(enable
                        ? 'NNTDrive will start when you sign in.'
                        : 'NNTDrive will no longer start when you sign in.');
                  } else {
                    _showError(
                        'Could not ${enable ? 'enable' : 'disable'} login autostart: $failure');
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('Check for updates'),
              subtitle: Text(Platform.isAndroid
                  ? 'Downloads, verifies and opens the Android installer'
                  : 'Windows and Linux update in place'),
              onTap: () {
                Navigator.pop(context);
                _checkForUpdates();
              },
            ),
            ListTile(
              leading: const Icon(Icons.contrast),
              title: const Text('Appearance'),
              onTap: () {
                Navigator.pop(context);
                showDialog<void>(context: this.context, builder: (_) =>
                  AppearanceDialog(
                    themeMode: widget.themeMode,
                    density: widget.browserDensity,
                    onTheme: widget.onTheme,
                    onDensity: (density) => widget.onBrowserDensity?.call(density),
                  ));
              },
            ),
            if (widget.onRenameDevice != null) ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename this device'),
              onTap: () {
                Navigator.pop(context);
                widget.onRenameDevice!();
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () {
                Navigator.pop(context);
                widget.onSignOut();
              },
            ),
          ],
        )),
      ),
    );
  }

  Future<void> _showDevices() async {
    _dismissDetails();
    _advanceNavigation();
    try {
      final devices = await _api.devices();
      final roots = await widget.operations.run(widget.session.handle, () =>
        AccountRootsService(api: _api,
          sealName: (id, name) => NativeBridge.instance.sealName(widget.session.handle, id, name),
          openName: (id, sealed) => NativeBridge.instance.openName(widget.session.handle, id, sealed),
        ).refresh());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Devices'),
          content: SizedBox(
            width: 520,
            child: ListView(
              shrinkWrap: true,
              children: devices
                  .map((d) => ListTile(
                        leading: Icon(d.revoked ? Icons.block : Icons.devices),
                        title: Text('${roots.where((r) => r.deviceId == d.id).firstOrNull?.deviceName ?? 'Device'} (${d.platform})'),
                        subtitle: Text(d.revoked ? 'revoked' : d.id),
                        trailing: d.revoked
                            ? null
                            : TextButton(
                                onPressed: () async {
                                  final revoked = await _api.revokeDevice(d.id);
                                  if (!context.mounted) return;
                                  Navigator.pop(context);
                                  await _afterDeviceRevoked(revoked);
                                },
                                child: const Text('Revoke'),
                              ),
                      ))
                  .toList(),
            ),
          ),
          actions: [
            if (widget.onRotateAccountKey != null)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  unawaited(_rotateKeyNow());
                },
                child: const Text('Rotate account key'),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  /// Asks the user to rotate the account key after a revoke that needs it.
  ///
  /// The server reports `key_rotation_required` because the revoked device can
  /// still read everything sealed under the current epoch. Rotation is never
  /// automatic: it needs the password and, with a stored kit, the recovery
  /// code. Staying on the old key is reported honestly instead of pretended.
  Future<void> _afterDeviceRevoked(DeviceRevokeResult result) async {
    final rotate = widget.onRotateAccountKey;
    if (!result.keyRotationRequired || rotate == null) return;
    if (!mounted) return;
    final rotated = await offerRotationAfterRevoke(
      result,
      confirm: () => confirmKeyRotation(context),
      rotate: rotate,
    );
    if (!mounted) return;
    _reportRotation(rotated);
  }

  /// Rotates the key on demand, e.g. when the prompt was declined earlier.
  Future<void> _rotateKeyNow() async {
    final rotate = widget.onRotateAccountKey;
    if (rotate == null) return;
    final rotated = await rotate();
    if (!mounted) return;
    _reportRotation(rotated);
  }

  void _reportRotation(bool rotated) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(rotated
            ? 'Account key rotated. The revoked device cannot read new content.'
            : 'The account key was not rotated, so a revoked device can still read '
                'content stored before now. Rotate it from Devices when you are ready.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = _me;
    final filtered = _browserListing.visible(
        _browserSort, _browserDescending, _search);
    final space = _currentSpace;
    final spaceNotice = staleSpaceWriteNotice(space);
    return Shortcuts(
      shortcuts: _browserKeys,
      child: Actions(
        actions: <Type, Action<Intent>>{
          BrowserCommandIntent: CallbackAction<BrowserCommandIntent>(
            onInvoke: (intent) {
              if (intent.id == 'close-details') {
                if (_browserCommandsReady && _detailsPane != null) _dismissDetails();
              } else if (_admitBrowserKey) {
                _runBrowserCommand(intent.id);
              }
              return null;
            }),
        },
        child: Focus(focusNode: _browserFocus, autofocus: true, child: SessionNavigation(
      selected: _path.isEmpty ? SessionDestination.devices
          : space?.isGlobal == true ? SessionDestination.global : null,
      onSelected: _selectDestination,
      child: Scaffold(
      appBar: AppBar(
        toolbarHeight: MediaQuery.textScalerOf(context).scale(56),
        leading: _path.isEmpty
            ? null
            : IconButton(onPressed: _up, icon: const Icon(Icons.arrow_back), tooltip: 'Up one folder'),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_path.isEmpty ? 'My files' : _name(_path.last),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            if (me != null)
              Text(
                '${_formatBytes(me.used)}${me.quota == null ? '' : ' of ${_formatBytes(me.quota!)}'} · end-to-end encrypted',
                style: theme.textTheme.bodySmall,
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(onPressed: _openAccountSearch, icon: const Icon(Icons.travel_explore),
            tooltip: 'Search all files'),
          IconButton(
            onPressed: _openSync,
            tooltip: 'Sync folders',
            icon: Badge(
              isLabelVisible: _sync.conflictCount > 0 || _sync.folders.any((f) => f.hasErrors),
              label: _sync.conflictCount > 0 ? Text('${_sync.conflictCount}') : null,
              child: _sync.syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            ),
          ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          IconButton(onPressed: _openTrash, icon: const Icon(Icons.delete_outline),
            tooltip: 'Trash'),
          IconButton(
            onPressed: _showAccountMenu,
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Account',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(MediaQuery.textScalerOf(context).scale(52)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _folderFilter,
              focusNode: _folderFilterFocus,
              onChanged: (v) {
                _clearSelection(exit: false);
                setState(() => _search = v);
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter this folder',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ),
      ),
      body: _backScope(_detailsLayout(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (space != null && spaceNotice != null)
            SpaceWriteNotice(root: space, message: spaceNotice),
          Row(children: [
            IconButton(tooltip: 'Back in listing history',
              onPressed: _browserCommandsReady && _historyIndex > 0 ? () => _historyStep(-1) : null,
              icon: const Icon(Icons.arrow_back)),
            IconButton(tooltip: 'Forward in listing history',
              onPressed: _browserCommandsReady && _historyIndex + 1 < _listingHistory.length
                  ? () => _historyStep(1) : null,
              icon: const Icon(Icons.arrow_forward)),
            Expanded(child: BrowserBreadcrumbs(names: _path.map(_name).toList(),
              onVisit: _breadcrumbVisitor)),
            if (!_selectionMode) _selectionControls(filtered),
          ]),
          if (_selectionMode) _selectionControls(filtered)
          else Align(alignment: Alignment.centerLeft, child: Wrap(children: [
            TextButton.icon(
              onPressed: _browserCommandsReady ? () => _showCommands() : null,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.keyboard_command_key),
              label: const Tooltip(message: 'Commands (Ctrl/Cmd+K)', child: Text('Commands')),
            ),
            TextButton(
              onPressed: _browserCommandsReady ? () => _showCommands(help: true) : null,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('Shortcut help'),
            ),
          ])),
          BrowserViewControls(
            view: _browserView, sort: _browserSort, descending: _browserDescending,
            onView: (value) => setState(() => _browserView = value),
            onSort: (value) => setState(() => _browserSort = value),
            onDirection: () => setState(() => _browserDescending = !_browserDescending),
          ),
          Expanded(
            child: _loading
                ? const BrowserLoadingSkeleton()
                : _error != null
                    ? BrowserListingNotice(
                        icon: Icons.cloud_off, isError: true,
                        title: 'Could not load this folder', message: _error!,
                        actions: [FilledButton(onPressed: _refresh,
                          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                          child: const Text('Retry'))],
                      )
                    : filtered.isEmpty
                        ? (_search.isEmpty
                          ? BrowserListingNotice(
                              icon: Icons.folder_open, title: 'This folder is empty',
                              message: 'Upload a file or create a folder to get started.',
                              actions: [
                                FilledButton(onPressed: _upload,
                                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                                  child: const Text('Upload a file')),
                                OutlinedButton(onPressed: _createFolder,
                                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                                  child: const Text('Create folder')),
                              ],
                            )
                          : BrowserListingNotice(
                              icon: Icons.search_off, title: 'No matching files',
                              message: 'Try a different folder filter or clear it to see all items.',
                              actions: [FilledButton(
                                onPressed: () => setState(() { _search = ''; _folderFilter.clear(); }),
                                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                                child: const Text('Clear filter'))],
                            ))
                        : RefreshIndicator(
                      onRefresh: _refresh,
                      child: BrowserFilesView(
                        density: widget.browserDensity,
                        files: filtered,
                        view: _browserView,
                        nameFor: _name,
                        availabilityFor: (f) => _availability[f.id] ?? LocalAvailability.unknown,
                        pinned: (f) => _offlinePins.contains(_pinKey(f.id, f.currentVersion ?? '')),
                        onOpen: _open,
                        onActions: _itemActions,
                        onReveal: _revealLocal,
                        onDetails: _detailsCallback,
                        isSelected: (file) => identical(_selectedFiles[file.id], file),
                        onToggleSelection: _selectionCallback,
                      ),
              ),
          ),
        ],
      ))),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            top: false,
            child: Padding(
              // Keep the last row above the keyboard as well as the nav bar.
              padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.upload_file),
                    title: const Text('Upload a file'),
                    subtitle: const Text('Encrypted and erasure-coded locally'),
                    onTap: () {
                      Navigator.pop(context);
                      _upload();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.create_new_folder_outlined),
                    title: const Text('New folder'),
                    onTap: () {
                      Navigator.pop(context);
                      _createFolder();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        tooltip: 'New',
        child: const Icon(Icons.add),
      ),
      ),
    ))));
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  double value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String formatBytes(int bytes) => _formatBytes(bytes);
