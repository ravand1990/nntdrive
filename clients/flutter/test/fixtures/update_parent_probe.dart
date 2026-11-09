// A real PE parent/restart fixture, compiled by the Windows regression test.
// No Flutter binding or mocked Process: the parent holds its own installed
// executable open and exits only after the production detached handoff.
import 'dart:io';

import 'package:nntdrive/update_handoff.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    final state = await launchWindowsUpdateHelper(
      stage: Directory(args[0]),
      install: args[1],
      parentPid: pid,
      showFailureDialog: false,
    );
    File('${args[1]}/handoff-state').writeAsStringSync(state.path);
    exit(0);
  }
  // The helper restarts the new executable without arguments. Keep it alive
  // until the supervisor verifies the marker, then terminates this exact PID.
  final install = File(Platform.resolvedExecutable).parent;
  final marker = File('${install.path}/restarted-pid.tmp');
  marker.writeAsStringSync('$pid');
  marker.renameSync('${install.path}/restarted-pid');
  await Future<void>.delayed(const Duration(minutes: 1));
}
