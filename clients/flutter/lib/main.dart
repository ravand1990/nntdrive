import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'account_search.dart';
import 'search_page.dart';
import 'desktop_host.dart';
import 'desktop_instance.dart';
import 'desktop_lifecycle.dart';
import 'session_operations.dart';
import 'local_availability.dart';
import 'local_availability_widgets.dart';
import 'file_rename.dart';
import 'file_move.dart';
import 'file_copy.dart';
import 'move_dialog.dart';
import 'rename_dialog.dart';
import 'native.dart';
import 'reference_backfill.dart';
import 'sync_controller.dart';
import 'sync_page.dart';
import 'updater.dart';
import 'update_checks.dart';
import 'update_prompt.dart';

const _uuid = Uuid();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
}

class NntDriveApp extends StatefulWidget {
  const NntDriveApp({super.key, required this.prefs, this.instance});
  final SharedPreferences prefs;
  final DesktopInstance? instance;

  @override
  State<NntDriveApp> createState() => _NntDriveAppState();
}

class _NntDriveAppState extends State<NntDriveApp> {
  late ThemeMode _themeMode;
  late String _server;
  String? _token;
  String? _keyfile;
  String? _accountId;
  String? _email;
  Session? _session;
  SyncController? _sync;
  DesktopLifecycle? _desktop;
  String? _desktopError;
  String? _trayState;
  String? _shutdownError;
  bool _ending = false;
  Future<void>? _endFuture;
  Future<void>? _authFuture;
  final _fileOperations = SessionOperations();
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final UpdateChecks _updates = UpdateChecks(
    check: () async => Updater(await Updater.loadConfig()).check(),
    prompt: (info) async {
      final context = _navigatorKey.currentState?.overlay?.context;
      if (context != null && context.mounted) {
        await promptUpdate(context, info, _formatBytes(info.size));
      }
    },
  );

  @override
  void dispose() {
    _updates.dispose();
    _desktop?.dispose();
    _sync?.removeListener(_updateTray);
    _sync?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _themeMode = ThemeMode.values[widget.prefs.getInt('theme') ?? 0];
    _server = widget.prefs.getString('server') ?? 'http://127.0.0.1:8080';
    _token = widget.prefs.getString('token');
    _keyfile = widget.prefs.getString('keyfile');
    _accountId = widget.prefs.getString('accountId');
    _email = widget.prefs.getString('email');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Updater.supported) _updates.start();
      if (widget.instance != null) unawaited(_startDesktop());
    });
  }

  void _setTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    widget.prefs.setInt('theme', mode.index);
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
        if (!_ending && sync != null) await sync.setPaused(!sync.paused);
      },
      onError: (message) {
        if (mounted) setState(() => _desktopError = message);
      },
    );
    await _desktop!.start();
    _updateTray();
    if (mounted) setState(() {});
  }

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
    final state = '$status|${sync != null && !_ending}|${sync?.paused ?? true}';
    if (_trayState == state) return; // Byte-progress events do not rebuild menus.
    _trayState = state;
    unawaited(_desktop?.update(status,
        canPause: sync != null && !_ending, paused: sync?.paused ?? true));
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
    final unlocked = await NativeBridge.instance.unlockAsync(keyfileJson, password);
    var adopted = false;
    try {
      if (!mounted || _ending) return;
      await widget.prefs.setString('server', server);
      await widget.prefs.setString('token', token);
      await widget.prefs.setString('keyfile', keyfileJson);
      await widget.prefs.setString('accountId', accountId);
      await widget.prefs.setString('email', email);
      if (!mounted || _ending) return;
      final sync = SyncController(
        server: server,
        token: token,
        handle: unlocked['handle'] as int,
        api: ApiClient(baseUrl: server, token: token),
      );
      _sync = sync;
      sync.addListener(_updateTray);
      unawaited(sync.load().then((_) => sync.start()));
      setState(() {
        _server = server;
        _token = token;
        _keyfile = keyfileJson;
        _accountId = accountId;
        _email = email;
        _session = Session(
          server: server,
          token: token,
          handle: unlocked['handle'] as int,
          accountId: accountId,
          email: email,
          operations: _fileOperations,
        );
      });
      adopted = true;
      _updateTray();
    } finally {
      if (!adopted) NativeBridge.instance.lock(unlocked['handle'] as int);
    }
  }

  void _signOut() => unawaited(_endSession(signOut: true).catchError((Object _) {
    // The failed drain stays locked down; the overlay exposes explicit retry.
  }));

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
    await widget.prefs.remove('token');
    await widget.prefs.remove('keyfile');
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

  ThemeData _theme(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0B6BCB),
        brightness: brightness,
      );

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (_session != null) {
      home = FilesPage(
        key: ValueKey('${_session!.accountId}:${_session!.handle}'),
        session: _session!,
        sync: _sync!,
        operations: _fileOperations,
        updates: _updates,
        themeMode: _themeMode,
        onTheme: _setTheme,
        onSignOut: _signOut,
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
      );
    } else {
      home = LoginPage(initialServer: _server, onAuthenticated: _completeAuth);
    }
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'NNTDrive',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _themeMode,
      home: home,
      builder: (context, child) => Column(children: [
        Expanded(child: Stack(children: [
          FocusScope(canRequestFocus: !_ending,
              child: AbsorbPointer(absorbing: _ending, child: child!)),
          if (_ending) Positioned.fill(child: Material(
            color: const Color(0xDDFFFFFF), child: Center(child: Column(
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
      ]),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.initialServer, required this.onAuthenticated});
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
            'name': Platform.localHostname,
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
            'name': Platform.localHostname,
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
            const Icon(Icons.check_circle, color: Colors.green),
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
  });
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
              ],
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
  });
  final Session session;
  final SyncController sync;
  final SessionOperations operations;
  final UpdateChecks updates;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onTheme;
  final VoidCallback onSignOut;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  late final ApiClient _api =
      ApiClient(baseUrl: widget.session.server, token: widget.session.token);
  final List<RemoteFile> _path = [];
  List<RemoteFile> _files = [];
  final Map<String, String> _names = {};
  AccountInfo? _me;
  bool _loading = true;
  String? _error;
  String _search = '';
  final _folderFilter = TextEditingController();
  late final SyncController _sync;
  bool _wasSyncing = false;
  bool _syncLoaded = false;
  Map<String, LocalAvailability> _availability = {};
  int _refreshGeneration = 0;

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
    _refresh();
  }

  void _onSyncChanged() {
    if (!mounted) return;
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
    _folderFilter.dispose();
    super.dispose();
  }

  Future<void> _openAccountSearch() async {
    final index = widget.session.search;
    final entry = await Navigator.of(context).push<SearchEntry>(MaterialPageRoute(
      builder: (_) => AccountSearchPage(index: index),
    ));
    if (entry == null || !mounted || !index.ready) return;
    final parents = index.ancestors(entry);
    setState(() {
      _search = '';
      _folderFilter.clear();
      _path
        ..clear()
        ..addAll(parents.map((e) => e.file));
      if (entry.file.isDir) _path.add(entry.file);
    });
    await _refresh(); // Resolve current state before offering file actions.
    if (!mounted || !index.ready || _error != null || entry.file.isDir) return;
    final current = _files.where((file) => file.id == entry.file.id).firstOrNull;
    if (current != null) _open(current);
  }

  Future<void> _openSync() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SyncPage(controller: _sync),
    ));
    if (mounted) _refresh();
  }

  Future<void> _refresh() => _fileOperation(_refreshNow);

  Future<void> _refreshNow() async {
    final generation = ++_refreshGeneration;
    final parentIds = _path.map((entry) => entry.id).toList();
    setState(() {
      _loading = true;
      _availability = {};
      _error = null;
    });
    try {
      final me = await _api.me();
      final files = await _api.listFiles(parentId: parentIds.lastOrNull);
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
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _availability = availability;
        _me = me;
        _files = files;
        _names
          ..clear()
          ..addAll(names);
      });
    } on ApiException catch (e) {
      if (!mounted || generation != _refreshGeneration) return;
      if (e.status == 401) {
        widget.onSignOut();
        return;
      }
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _open(RemoteFile file) {
    if (file.isDir) {
      setState(() => _path.add(file));
      _refresh();
      return;
    }
    _showFileActions(file);
  }

  void _up() {
    if (_path.isEmpty) return;
    setState(() => _path.removeLast());
    _refresh();
  }

  String _name(RemoteFile f) => _names[f.id] ?? (f.isDir ? 'Encrypted folder' : 'Encrypted file');

  bool _renaming = false;

  Future<void> _copy(RemoteFile file) async {
    if (_renaming) return;
    setState(() => _renaming = true);
    try {
      final destination = await showDialog<MoveDestination>(context: context,
        builder: (_) => MoveDialog(api: _api, handle: widget.session.handle,
          operations: widget.operations, source: file, copy: true));
      if (destination == null || !mounted) return;
      final attempted = await showDialog<bool>(context: context,
        barrierDismissible: false,
        builder: (_) => CopyFileDialog(isDir: file.isDir,
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
    try {
      final destination = await showDialog<MoveDestination>(context: context,
        builder: (_) => MoveDialog(api: _api, handle: widget.session.handle,
          operations: widget.operations, source: file));
      if (destination == null || !mounted) return;
      await widget.operations.run(widget.session.handle, () =>
        moveRemoteEntry(api: _api, handle: widget.session.handle,
          file: file, parentId: destination.parentId));
      if (mounted) await _refresh();
    } on RenameFailure catch (e) {
      if (mounted) _showError(e.message);
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
      await widget.operations.run(widget.session.handle, () =>
        renameRemoteEntry(api: _api, handle: widget.session.handle,
          file: file, name: name));
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
      builder: (context) => AlertDialog(
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
    final id = _uuid.v4();
    try {
      final sealed = NativeBridge.instance.sealName(widget.session.handle, id, name);
      await _api.createFile(
        id: id,
        parentId: _path.isEmpty ? null : _path.last.id,
        nameEnc: sealed,
        isDir: true,
      );
      await _refresh();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _upload() async {
    const group = XTypeGroup(label: 'All files');
    final picked = await openFile(acceptedTypeGroups: const [group]);
    if (picked == null) return;
    await _fileOperation(() => _uploadPicked(picked.path));
  }

  Future<void> _uploadPicked(String path) async {
    final name = p.basename(path);
    final fileId = _uuid.v4();
    final revisionId = _uuid.v4();
    try {
      final sealed = NativeBridge.instance.sealName(widget.session.handle, fileId, name);
      await _api.createFile(
        id: fileId,
        parentId: _path.isEmpty ? null : _path.last.id,
        nameEnc: sealed,
        isDir: false,
      );
      _showProgress('Encrypting and uploading $name');
      final result = await NativeBridge.instance.uploadAsync(
        handle: widget.session.handle,
        baseUrl: widget.session.server,
        token: widget.session.token,
        fileId: fileId,
        revisionId: revisionId,
        parentRevision: '',
        path: path,
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
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
    final revisionId = _uuid.v4();
    _showProgress('Uploading a new version of ${_name(file)}');
    try {
      final result = await NativeBridge.instance.uploadAsync(
        handle: widget.session.handle,
        baseUrl: widget.session.server,
        token: widget.session.token,
        fileId: file.id,
        revisionId: revisionId,
        parentRevision: file.currentVersion ?? '',
        path: path,
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
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

  Future<void> _downloadTo(RemoteFile file, String destination, String? revisionId) async {
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
    try {
      final versions = await _api.versions(file.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Versions — ${_name(file)}'),
          content: SizedBox(
            width: 520,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: versions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final v = versions[i];
                return ListTile(
                  dense: true,
                  title: Text(v.createdAt),
                  subtitle: Text('${_formatBytes(v.size)} · ${v.revisionId}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: 'Download this version',
                    onPressed: () {
                      Navigator.pop(context);
                      _download(file,
                          revisionId: v.revisionId,
                          asName: '${p.basenameWithoutExtension(_name(file))} '
                              '(${v.createdAt.substring(0, 10)})'
                              '${p.extension(_name(file))}');
                    },
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  void _showFileActions(RemoteFile file) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: Text(_name(file)),
              subtitle: Text('${_formatBytes(file.size)} · revision ${file.revision}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Download and verify'),
              onTap: () {
                Navigator.pop(context);
                _download(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Version history'),
              onTap: () {
                Navigator.pop(context);
                _showVersions(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.upgrade),
              title: const Text('Upload new version'),
              subtitle: const Text('Keeps the previous revision recoverable'),
              onTap: () {
                Navigator.pop(context);
                _uploadRevision(file);
              },
            ),
            ListTile(
              leading: Icon(file.favorite ? Icons.star : Icons.star_border),
              title: Text(file.favorite ? 'Remove favorite' : 'Add favorite'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  await _api.setFavorite(file.id, !file.favorite);
                  await _refresh();
                } catch (e) {
                  _showError(e);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(context);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete file?'),
                    content: const Text(
                        'This removes the file and its versions from the index. '
                        'Posted Usenet articles cannot be physically deleted.'),
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
                if (ok == true) {
                  try {
                    await _api.deleteFile(file.id);
                    await _refresh();
                  } catch (e) {
                    _showError(e);
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
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
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
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
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Update settings'),
              subtitle: const Text('Repository and access token'),
              onTap: () {
                Navigator.pop(context);
                _showUpdateSettings();
              },
            ),
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('Check for updates'),
              subtitle: const Text('Windows and Linux update in place'),
              onTap: () {
                Navigator.pop(context);
                _checkForUpdates();
              },
            ),
            ListTile(
              leading: const Icon(Icons.contrast),
              title: const Text('Toggle theme'),
              onTap: () {
                Navigator.pop(context);
                widget.onTheme(switch (widget.themeMode) {
                  ThemeMode.system => ThemeMode.light,
                  ThemeMode.light => ThemeMode.dark,
                  ThemeMode.dark => ThemeMode.system,
                });
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
        ),
      ),
    );
  }

  Future<void> _showDevices() async {
    try {
      final devices = await _api.devices();
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
                        title: Text('${d.name} (${d.platform})'),
                        subtitle: Text(d.revoked ? 'revoked' : d.id),
                        trailing: d.revoked
                            ? null
                            : TextButton(
                                onPressed: () async {
                                  await _api.revokeDevice(d.id);
                                  if (context.mounted) Navigator.pop(context);
                                },
                                child: const Text('Revoke'),
                              ),
                      ))
                  .toList(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = _me;
    final filtered = _search.isEmpty
        ? _files
        : _files.where((f) => _name(f).toLowerCase().contains(_search.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(
        leading: _path.isEmpty
            ? null
            : IconButton(onPressed: _up, icon: const Icon(Icons.arrow_back), tooltip: 'Up'),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_path.isEmpty ? 'My files' : _name(_path.last)),
            if (me != null)
              Text(
                '${_formatBytes(me.used)}${me.quota == null ? '' : ' of ${_formatBytes(me.quota!)}'} · end-to-end encrypted',
                style: theme.textTheme.bodySmall,
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
          IconButton(
            onPressed: _showAccountMenu,
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Account',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _folderFilter,
              onChanged: (v) => setState(() => _search = v),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _refresh)
              : filtered.isEmpty
                  ? const _EmptyView()
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final f = filtered[i];
                          final local = _availability[f.id] ?? LocalAvailability.unknown;
                          return ListTile(
                            leading: Icon(f.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
                            title: Text(_name(f)),
                            subtitle: LocalAvailabilityLabel(
                              state: local,
                              details: f.isDir ? 'Folder' : _formatBytes(f.size),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (f.favorite) const Icon(Icons.star, size: 18),
                                LocalRevealButton(
                                  state: local,
                                  onReveal: () => _revealLocal(f),
                                ),
                                IconButton(
                                  tooltip: f.isDir ? 'Rename folder' : 'Rename file',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: _renaming ? null : () => _rename(f),
                                ),
                                IconButton(
                                  tooltip: f.isDir ? 'Move folder' : 'Move file',
                                  icon: const Icon(Icons.drive_file_move_outlined),
                                  onPressed: _renaming ? null : () => _move(f),
                                ),
                                CopyFileButton(isDir: f.isDir, busy: _renaming,
                                  onCopy: () => _copy(f)),
                                if (f.isDir) const Icon(Icons.chevron_right),
                              ],
                            ),
                            onTap: () => _open(f),
                          );
                        },
                      ),
                    ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
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
        tooltip: 'New',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 44),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open, size: 48),
            const SizedBox(height: 10),
            Text('This folder is empty', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Use + to upload a file or create a folder.'),
          ],
        ),
      );
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
