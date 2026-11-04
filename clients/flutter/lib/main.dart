import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'native.dart';

const _uuid = Uuid();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(NntDriveApp(prefs: prefs));
}

class Session {
  Session({
    required this.server,
    required this.token,
    required this.handle,
    required this.accountId,
    required this.email,
  });
  final String server;
  final String token;
  final int handle;
  final String accountId;
  final String email;
}

class NntDriveApp extends StatefulWidget {
  const NntDriveApp({super.key, required this.prefs});
  final SharedPreferences prefs;

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

  @override
  void initState() {
    super.initState();
    _themeMode = ThemeMode.values[widget.prefs.getInt('theme') ?? 0];
    _server = widget.prefs.getString('server') ?? 'http://127.0.0.1:8080';
    _token = widget.prefs.getString('token');
    _keyfile = widget.prefs.getString('keyfile');
    _accountId = widget.prefs.getString('accountId');
    _email = widget.prefs.getString('email');
  }

  void _setTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    widget.prefs.setInt('theme', mode.index);
  }

  Future<void> _completeAuth({
    required String server,
    required String token,
    required String keyfileJson,
    required String accountId,
    required String email,
    required String password,
  }) async {
    final unlocked = await NativeBridge.instance.unlockAsync(keyfileJson, password);
    await widget.prefs.setString('server', server);
    await widget.prefs.setString('token', token);
    await widget.prefs.setString('keyfile', keyfileJson);
    await widget.prefs.setString('accountId', accountId);
    await widget.prefs.setString('email', email);
    if (!mounted) return;
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
      );
    });
  }

  void _signOut() {
    final handle = _session?.handle;
    if (handle != null) {
      NativeBridge.instance.lock(handle);
    }
    widget.prefs.remove('token');
    setState(() {
      _session = null;
      _token = null;
    });
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
        session: _session!,
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
      title: 'NNTDrive',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _themeMode,
      home: home,
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
  String? _error;

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

        final code = account['recovery_code'] as String;
        if (mounted) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('Save your recovery code'),
              content: SelectableText(
                '$code\n\n'
                'This code is shown once and is required to recover your encryption key. '
                'Store it offline, separately from your server backups. Nobody, including the server, can reset it.',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('I saved it'),
                ),
              ],
            ),
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
                const SizedBox(height: 24),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Sign in')),
                    ButtonSegment(value: true, label: Text('Create account')),
                  ],
                  selected: {_register},
                  onSelectionChanged: _busy
                      ? null
                      : (s) => setState(() {
                            _register = s.first;
                            _error = null;
                          }),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _server,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://drive.example.com',
                    border: OutlineInputBorder(),
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
                        : Text(_register ? 'Create encrypted account' : 'Unlock'),
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
    required this.session,
    required this.themeMode,
    required this.onTheme,
    required this.onSignOut,
  });
  final Session session;
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = await _api.me();
      final files = await _api.listFiles(parentId: _path.isEmpty ? null : _path.last.id);
      final bridge = NativeBridge.instance;
      final names = <String, String>{};
      for (final f in files) {
        try {
          names[f.id] = bridge.openName(widget.session.handle, f.id, f.nameEnc);
        } catch (_) {
          names[f.id] = f.isDir ? 'Encrypted folder' : 'Encrypted file';
        }
      }
      if (!mounted) return;
      setState(() {
        _me = me;
        _files = files;
        _names
          ..clear()
          ..addAll(names);
      });
    } on ApiException catch (e) {
      if (e.status == 401) {
        widget.onSignOut();
        return;
      }
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
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
    final path = picked.path;
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
        path: picked.path,
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
    _showProgress('Downloading and verifying $name');
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
                          return ListTile(
                            leading: Icon(f.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
                            title: Text(_name(f)),
                            subtitle: Text(f.isDir ? 'Folder' : _formatBytes(f.size)),
                            trailing: f.favorite
                                ? const Icon(Icons.star, size: 18)
                                : (f.isDir ? const Icon(Icons.chevron_right) : null),
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
