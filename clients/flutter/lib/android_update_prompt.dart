import 'package:flutter/material.dart';

import 'android_update.dart';
import 'release_notes.dart';

/// Shows the Android update prompt and, on confirmation, downloads the verified
/// package and opens the system installer.
///
/// Android always asks the user to confirm the upgrade, so this never claims the
/// update is finished. A missing "install unknown apps" switch is explained
/// once, with a settings link, and never retried in a loop.
Future<bool> promptAndroidUpdate(
  BuildContext context,
  AndroidUpdater updater,
  AndroidUpdateInfo info,
  String sizeLabel,
) async {
  if (!context.mounted) return false;
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
              Text('A newer NNTDrive Android build is available'
                  '${info.size > 0 ? ' ($sizeLabel)' : ''}. '
                  'It is downloaded over HTTPS, checked against the published '
                  'checksum and opened in the Android installer, where you '
                  'confirm the upgrade. Your account, keys and sync folder stay '
                  'in place.'),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                ReleaseNotesView(notes: info.notes),
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
            child: const Text('Download and install')),
      ],
    ),
  );
  if (!context.mounted) return false;
  if (go != true) {
    await updater.defer(info);
    return true;
  }
  if (!context.mounted) return false;

  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
        content: Row(children: [
      CircularProgressIndicator(),
      SizedBox(width: 20),
      Text('Downloading and verifying update…'),
    ])),
  );
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.push(progress);
  AndroidInstallStart start;
  try {
    start = await updater.install(info);
  } catch (error) {
    if (progress.isActive) navigator.removeRoute(progress);
    if (!context.mounted) return false;
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
    return true;
  }
  if (progress.isActive) navigator.removeRoute(progress);
  if (!context.mounted) return false;

  if (start.needsPermission) {
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Allow installs for NNTDrive'),
              content: const Text(
                  'Android only installs an app update if NNTDrive is allowed '
                  'to install unknown apps. Open the switch, enable it for '
                  'NNTDrive, then use "Check for updates" again. Nothing was '
                  'changed on this device.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Not now')),
                FilledButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      try {
                        await updater.openInstallSettings();
                      } on Exception {
                        // The dialog already explains the manual path.
                      }
                    },
                    child: const Text('Open settings')),
              ],
            ));
    return true;
  }
  if (!start.started) {
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Update could not start'),
              content: const Text('Android refused to open the installer. '
                  'Nothing was changed; try again later.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'))
              ],
            ));
    return true;
  }
  await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
            title: Text('Finish updating to ${info.version}'),
            content: const Text(
                'The Android installer is open. Confirm the upgrade there to '
                'replace the app; cancelling keeps the current version and its '
                'data. If the installer does not appear, check for NNTDrive '
                'in recent apps.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'))
            ],
          ));
  return true;
}
