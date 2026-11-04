import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'crypto_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(NntDriveApp(prefs: prefs));
}

class NntDriveApp extends StatefulWidget {
  const NntDriveApp({super.key, required this.prefs});
  final SharedPreferences prefs;

  @override
  State<NntDriveApp> createState() => _NntDriveAppState();
}

class _NntDriveAppState extends State<NntDriveApp> {
  late ThemeMode _themeMode;
  late String _serverUrl;
  String? _token;

  @override
  void initState() {
    super.initState();
    _themeMode = ThemeMode.values[widget.prefs.getInt('theme') ?? 0];
    _serverUrl = widget.prefs.getString('server') ?? 'http://127.0.0.1:8080';
    _token = widget.prefs.getString('token');
  }

  void _setTheme(ThemeMode mode) {
    setState(() => _themeMode = mode);
    widget.prefs.setInt('theme', mode.index);
  }

  void _setSession(String server, String? token) {
    setState(() {
      _serverUrl = server;
      _token = token;
    });
    widget.prefs.setString('server', server);
    if (token == null) {
      widget.prefs.remove('token');
    } else {
      widget.prefs.setString('token', token);
    }
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF0B6BCB),
        brightness: brightness,
        visualDensity: VisualDensity.standard,
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NNTDrive',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _themeMode,
      home: _token == null
          ? LoginPage(
              serverUrl: _serverUrl,
              onSignedIn: (server, token) => _setSession(server, token),
            )
          : FilesPage(
              serverUrl: _serverUrl,
              token: _token!,
              themeMode: _themeMode,
              onTheme: _setTheme,
              onSignOut: () => _setSession(_serverUrl, null),
            ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.serverUrl, required this.onSignedIn});
  final String serverUrl;
  final void Function(String server, String token) onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _server = TextEditingController(text: widget.serverUrl);
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _developerLogin() async {
    final token = _token.text.trim();
    if (token.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = ApiClient(baseUrl: _server.text.trim(), token: token);
    try {
      await api.me();
      widget.onSignedIn(api.baseUrl, token);
    } catch (e) {
      setState(() => _error = e.toString());
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
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_outlined, size: 40, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Text('NNTDrive', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 6),
                Text('Encrypted storage on Usenet', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 24),
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      'UI preview: the Rust cryptography bridge is not built yet. '
                      'Password login, decryption, uploads, downloads and sync are disabled. '
                      'You can explore files with a developer API token; names and content remain encrypted.',
                      style: TextStyle(color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _server,
                  decoration: const InputDecoration(labelText: 'Server URL', border: OutlineInputBorder()),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _email,
                  enabled: false,
                  decoration: const InputDecoration(
                    labelText: 'Email (requires native bridge)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _password,
                  enabled: false,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password (requires native bridge)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Developer sign-in', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                TextField(
                  controller: _token,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API token',
                    helperText: 'Mint one with: nntdrive token-create --account <id>',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _busy ? null : _developerLogin,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Open file browser'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
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
    required this.serverUrl,
    required this.token,
    required this.themeMode,
    required this.onTheme,
    required this.onSignOut,
  });
  final String serverUrl;
  final String token;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onTheme;
  final VoidCallback onSignOut;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  late final ApiClient _api = ApiClient(baseUrl: widget.serverUrl, token: widget.token);
  final List<RemoteFile> _path = [];
  List<RemoteFile> _files = [];
  AccountInfo? _me;
  bool _loading = true;
  String? _error;

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
      if (!mounted) return;
      setState(() {
        _me = me;
        _files = files;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(RemoteFile file) {
    if (!file.isDir) {
      _showPreviewInfo(file);
      return;
    }
    setState(() => _path.add(file));
    _refresh();
  }

  void _up() {
    if (_path.isEmpty) return;
    setState(() => _path.removeLast());
    _refresh();
  }

  void _showPreviewInfo(RemoteFile file) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sealed file', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('${formatBytes(file.size)} · revision ${file.revision}'),
            const SizedBox(height: 12),
            const Text('The name is encrypted with the account name key. Open it in a client with the Rust bridge to decrypt, preview or download it.'),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                try {
                  final versions = await _api.versions(file.id);
                  if (!context.mounted) return;
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Version history'),
                      content: SizedBox(
                        width: 480,
                        child: ListView(
                          shrinkWrap: true,
                          children: versions
                              .map((v) => ListTile(
                                    dense: true,
                                    title: Text(v.revisionId),
                                    subtitle: Text('${formatBytes(v.size)} · ${v.createdAt}'),
                                  ))
                              .toList(),
                        ),
                      ),
                      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
                    ),
                  );
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              },
              icon: const Icon(Icons.history),
              label: const Text('Version metadata'),
            ),
          ],
        ),
      ),
    );
  }

  void _disabled(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what requires the native Rust crypto bridge (see docs/CLIENTS.md).')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(
        leading: _path.isEmpty
            ? null
            : IconButton(onPressed: _up, icon: const Icon(Icons.arrow_back), tooltip: 'Up'),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_path.isEmpty ? 'My files' : 'Sealed folder'),
            if (me != null)
              Text(
                '${formatBytes(me.used)}${me.quota == null ? '' : ' of ${formatBytes(me.quota!)}'} · end-to-end encrypted',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'devices':
                  await _showDevices();
                case 'theme':
                  final next = switch (widget.themeMode) {
                    ThemeMode.system => ThemeMode.light,
                    ThemeMode.light => ThemeMode.dark,
                    ThemeMode.dark => ThemeMode.system,
                  };
                  widget.onTheme(next);
                case 'signout':
                  widget.onSignOut();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'devices', child: Text('Devices')),
              PopupMenuItem(value: 'theme', child: Text('Theme: ${widget.themeMode.name}')),
              const PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Text(
              'UI preview — names/content cannot be decrypted or synchronized without the Rust bridge.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _refresh)
              : _files.isEmpty
                  ? const _EmptyView()
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.separated(
                        itemCount: _files.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final f = _files[i];
                          return ListTile(
                            leading: Icon(f.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
                            title: Text(f.isDir ? 'Encrypted folder' : 'Encrypted file'),
                            subtitle: Text(
                              f.isDir ? 'Sealed name' : '${formatBytes(f.size)} · rev ${f.revision}',
                            ),
                            trailing: f.favorite ? const Icon(Icons.star, size: 18) : null,
                            onTap: () => _open(f),
                          );
                        },
                      ),
                    ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _disabled('Uploading'),
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload'),
      ),
    );
  }

  Future<void> _showDevices() async {
    try {
      final devices = await _api.devices();
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Devices'),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: devices
                  .map((d) => ListTile(
                        leading: Icon(d.revoked ? Icons.block : Icons.devices),
                        title: Text('${d.name} (${d.platform})${d.current ? ' — this device' : ''}'),
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
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
            const Text('Uploads require the native Rust bridge.'),
          ],
        ),
      );
}

String formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  double value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
