import 'dart:io';

import 'package:path/path.dart' as p;

/// Preference key that remembers the user's login-autostart opt-in.
const loginAutostartPreferenceKey = 'loginAutostartEnabled';

/// Raised when the OS registration could not be written or removed.
class LoginAutostartException implements Exception {
  const LoginAutostartException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Registers this client in the operating system's login-startup list.
abstract class LoginAutostart {
  /// Whether this platform can register a login item at all.
  bool get supported;

  /// Reads the OS login item without requiring account credentials.
  Future<bool> isEnabled();

  /// Adds or removes the login item for [executable].
  ///
  /// Throws [LoginAutostartException] when the platform refuses or the value
  /// cannot be validated. Callers persist the user's choice only after this
  /// returns normally.
  Future<void> apply({required bool enabled, required String executable});
}

/// Chooses the implementation for [operatingSystem] (defaults to this host).
///
/// The optional parameters exist so tests can use a temporary directory and a
/// fake process runner instead of touching the real login items.
LoginAutostart platformLoginAutostart({
  String? operatingSystem,
  Map<String, String>? environment,
  Directory? autostartDirectory,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
  runProcess,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  if (os == 'linux') {
    return LinuxLoginAutostart(
      environment: environment,
      autostartDirectory: autostartDirectory,
    );
  }
  if (os == 'windows') {
    return WindowsLoginAutostart(runProcess: runProcess);
  }
  return const UnsupportedLoginAutostart();
}

/// Linux registers autostart through an XDG desktop entry.
class LinuxLoginAutostart implements LoginAutostart {
  LinuxLoginAutostart({
    Map<String, String>? environment,
    Directory? autostartDirectory,
  }) : _environment = environment,
       _directory = autostartDirectory;

  static const fileName = 'nntdrive.desktop';

  final Map<String, String>? _environment;
  final Directory? _directory;

  @override
  bool get supported => true;

  /// The directory the entry belongs in: `$XDG_CONFIG_HOME/autostart`, else
  /// `$HOME/.config/autostart`.
  Directory get directory {
    final explicit = _directory;
    if (explicit != null) return explicit;
    final environment = _environment ?? Platform.environment;
    final configHome = environment['XDG_CONFIG_HOME']?.trim();
    if (configHome != null && configHome.isNotEmpty) {
      return Directory(p.join(configHome, 'autostart'));
    }
    final home = environment['HOME']?.trim();
    if (home == null || home.isEmpty) {
      throw const LoginAutostartException(
        'Cannot locate the autostart directory: HOME is not set.',
      );
    }
    return Directory(p.join(home, '.config', 'autostart'));
  }

  File get entryFile => File(p.join(directory.path, fileName));

  @override
  Future<bool> isEnabled() async {
    final file = entryFile;
    if (!await file.exists()) return false;
    final entry = await file.readAsLines();
    return entry.any((line) => line.startsWith('Exec=')) &&
        !entry.contains('Hidden=true') &&
        !entry.contains('X-GNOME-Autostart-enabled=false');
  }

  @override
  Future<void> apply({
    required bool enabled,
    required String executable,
  }) async {
    final file = entryFile;
    if (!enabled) {
      if (await file.exists()) await file.delete();
      return;
    }
    _requireExecutable(executable);
    await directory.create(recursive: true);
    final temp = File('${file.path}.tmp');
    try {
      await temp.writeAsString(desktopEntry(executable), flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}

/// Windows registers autostart through the per-user Run key.
class WindowsLoginAutostart implements LoginAutostart {
  WindowsLoginAutostart({
    Future<ProcessResult> Function(String executable, List<String> arguments)?
    runProcess,
  }) : _run = runProcess ?? Process.run;

  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const valueName = 'NNTDrive';

  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments,
  )
  _run;

  @override
  bool get supported => true;

  @override
  Future<bool> isEnabled() async {
    // reg.exe uses exit 1 for both missing values and access failures. Read via
    // the framework API instead, with explicit absence and failure outcomes.
    final result = await _run('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      r"$ErrorActionPreference='Stop'; try { "
      r"$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run'); "
      r"try { $value=if($null -eq $key){$null}else{$key.GetValue('NNTDrive')}; "
      r"if($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)){'off'}else{'on'} "
      r"} finally { if($null -ne $key){$key.Dispose()} } "
      r"} catch { exit 2 }",
    ]);
    final state = result.stdout.toString().trim();
    if (result.exitCode != 0 || !{'on', 'off'}.contains(state)) {
      throw const LoginAutostartException('Could not read the login item.');
    }
    return state == 'on';
  }

  @override
  Future<void> apply({
    required bool enabled,
    required String executable,
  }) async {
    if (enabled) _requireExecutable(executable);
    final result = await _run(
      'reg.exe',
      enabled ? registryAddArguments(executable) : registryDeleteArguments(),
    );
    // Deleting a value that is already absent exits with 1; that is the state
    // we want, so it is not an error.
    if (result.exitCode != 0 && !(enabled == false && result.exitCode == 1)) {
      throw LoginAutostartException(
        'Registry update failed (${result.exitCode}): ${_firstLine(result.stderr)}',
      );
    }
  }
}

/// Used on platforms without a desktop login-startup list.
class UnsupportedLoginAutostart implements LoginAutostart {
  const UnsupportedLoginAutostart();

  @override
  bool get supported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> apply({
    required bool enabled,
    required String executable,
  }) async {
    if (!enabled) return;
    throw const LoginAutostartException(
      'Login autostart is not supported on this platform.',
    );
  }
}

/// The complete desktop entry written on Linux.
String desktopEntry(String executable) =>
    '[Desktop Entry]\n'
    'Type=Application\n'
    'Name=NNTDrive\n'
    'Comment=Encrypted storage over Usenet\n'
    'Exec=${desktopEntryExec(executable)}\n'
    'Terminal=false\n'
    'X-GNOME-Autostart-enabled=true\n';

/// Quotes one executable path as an `Exec` value.
///
/// The desktop-entry spec reserves `"`, `` ` ``, `$` and `\` inside a quoted
/// argument and treats `%` as a field code, so each is escaped here.
String desktopEntryExec(String executable) {
  final escaped = executable
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$')
      .replaceAll('%', '%%');
  return '"$escaped"';
}

/// Arguments that add the Run entry.
List<String> registryAddArguments(String executable) => [
  'add',
  WindowsLoginAutostart.runKey,
  '/v',
  WindowsLoginAutostart.valueName,
  '/t',
  'REG_SZ',
  '/d',
  executable,
  '/f',
];

/// Arguments that remove the Run entry.
List<String> registryDeleteArguments() => [
  'delete',
  WindowsLoginAutostart.runKey,
  '/v',
  WindowsLoginAutostart.valueName,
  '/f',
];

void _requireExecutable(String executable) {
  if (executable.trim().isEmpty) {
    throw const LoginAutostartException(
      'Cannot register autostart without an executable path.',
    );
  }
}

String _firstLine(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 'no output';
  final newline = trimmed.indexOf('\n');
  return newline == -1 ? trimmed : trimmed.substring(0, newline);
}
