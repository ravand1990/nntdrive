import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'updater.dart';

/// Shared by startup and explicit checks. The caller serializes this entire flow.
Future<void> promptUpdate(
    BuildContext context, UpdateInfo info, String sizeLabel) async {
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Update available — ${info.version}'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('A newer NNTDrive client is available'
                  '${info.size > 0 ? ' ($sizeLabel)' : ''}. '
                  'It downloads, verifies and replaces this installation, then '
                  'restarts the app.'),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(info.notes, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install and restart')),
      ],
    ),
  );
  if (go != true) {
    await prefs.setString('updateSkippedVersion', info.version);
    return;
  }
  if (!context.mounted) return;
  // Keep a handle to this route: never pop an unrelated login/settings route.
  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
        content: Row(children: [
      CircularProgressIndicator(),
      SizedBox(width: 20),
      Text('Downloading update…'),
    ])),
  );
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.push(progress);
  try {
    await Updater(await Updater.loadConfig()).install(info);
    exit(0);
  } catch (error) {
    if (progress.isActive) navigator.removeRoute(progress);
    if (!context.mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Update failed'),
              content: Text('$error'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'))
              ],
            ));
  }
}
