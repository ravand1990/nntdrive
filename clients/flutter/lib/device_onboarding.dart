import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_roots.dart';
import 'api.dart';
import 'device_name.dart';
import 'file_rename.dart';
import 'native.dart';
import 'session_operations.dart';

/// Only opaque identity is persisted, not the confirmed name or a name hash.
String deviceConfirmationKey(
  String server,
  String accountId,
  String deviceId,
  String rootId,
) =>
    'deviceNameConfirmed.v1.${base64Url.encode(utf8.encode(jsonEncode([server, accountId, deviceId, rootId])))}';

class DeviceNaming {
  DeviceNaming({
    required this.api,
    required this.handle,
    required this.server,
    required this.accountId,
  });
  final ApiClient api;
  final int handle;
  final String server;
  final String accountId;

  AccountRootsService get roots => AccountRootsService(
    api: api,
    sealName: (id, name) => NativeBridge.instance.sealName(handle, id, name),
    openName: (id, sealed) =>
        NativeBridge.instance.openName(handle, id, sealed),
  );

  Future<AccountRoot> currentRoot() async {
    final result = await roots.ensure();
    final root = result.roots
        .where((r) => r.nodeId == result.deviceRootNodeId)
        .firstOrNull;
    if (root == null || root.deviceId == null) {
      throw StateError('No authenticated device space');
    }
    return root;
  }

  String key(AccountRoot root) =>
      deviceConfirmationKey(server, accountId, root.deviceId!, root.nodeId);

  Future<void> confirm(AccountRoot root, String name) async {
    final invalid = deviceNameValidationError(name);
    if (invalid != null) throw RenameFailure(invalid);
    // Refresh source identity and use the existing encrypted, guarded rename.
    // No move, recreate, manifest rewrite or journal reset is involved.
    final current = await currentRoot();
    if (current.nodeId != root.nodeId || current.deviceId != root.deviceId) {
      throw RenameFailure('The device space changed. Reload and try again.');
    }
    final siblings = await api.listFiles();
    final file = siblings.where((f) => f.id == root.nodeId).firstOrNull;
    if (file == null || !file.isDir || file.parentId != null) {
      throw RenameFailure(
        'The device space is unavailable. Reload and try again.',
      );
    }
    await renameRemoteEntry(api: api, handle: handle, file: file, name: name);
    // Read the exact target back before marking this identity confirmed.
    final updated = await currentRoot();
    if (updated.nodeId != root.nodeId || updated.deviceName != name) {
      throw RenameFailure(
        'The label could not be verified. Reload and try again.',
      );
    }
    await (await SharedPreferences.getInstance()).setBool(key(root), true);
  }
}

/// This page replaces the entire file/sync UI until confirmation succeeds.
/// An idle page owns no operation: Quit can drain without waiting for input.
class DeviceOnboardingPage extends StatefulWidget {
  const DeviceOnboardingPage({
    super.key,
    required this.naming,
    required this.operations,
    required this.onReady,
    required this.onSignOut,
    this.force = false,
    this.defaultName = readDeviceNameDefault,
  });
  final DeviceNaming naming;
  final SessionOperations operations;
  final Future<void> Function() onReady;
  final VoidCallback onSignOut;
  final bool force;
  final Future<String> Function() defaultName;

  @override
  State<DeviceOnboardingPage> createState() => _DeviceOnboardingPageState();
}

class _DeviceOnboardingPageState extends State<DeviceOnboardingPage> {
  final _name = TextEditingController();
  AccountRoot? _root;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.operations.run(widget.naming.handle, () async {
        final root = await widget.naming.currentRoot();
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        if (!widget.force &&
            prefs.getBool(widget.naming.key(root)) == true &&
            deviceNameValidationError(root.deviceName ?? '') == null) {
          await widget.onReady();
          return;
        }
        final suggested = widget.force
            ? root.deviceName ?? ''
            : await widget.defaultName();
        if (!mounted) return;
        setState(() {
          _root = root;
          _name.text = suggested;
        });
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not initialize this device space. Uploads and sync remain blocked. Retry or sign in again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    if (_busy || _root == null) return;
    final invalid = deviceNameValidationError(_name.text);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.operations.run(widget.naming.handle, () async {
        await widget.naming.confirm(_root!, _name.text);
        if (mounted) await widget.onReady();
      });
    } on RenameFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not confirm the encrypted label. Reload and try again. Uploads and sync remain blocked.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.force ? 'Rename this device' : 'Name this device'),
      actions: [
        TextButton(onPressed: widget.onSignOut, child: const Text('Sign out')),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Choose the name other devices in your account will see. '
                'The label is encrypted before leaving this device. '
                'Confirm before uploads or sync can start.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                enabled: !_busy && _root != null,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Device name'),
                onSubmitted: (_) => _confirm(),
              ),
              const SizedBox(height: 16),
              const Text(
                'Only the space label changes. Existing files, folder locations '
                'and version history are kept. Moving legacy folders is a separate, explicit action.',
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_busy) const LinearProgressIndicator(),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy || _root == null ? null : _confirm,
                child: const Text('Confirm device name'),
              ),
              TextButton(
                onPressed: _busy ? null : _load,
                child: const Text('Reload'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
