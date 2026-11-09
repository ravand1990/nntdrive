import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_lifecycle.dart';

class PluginDesktopHost extends DesktopHost with WindowListener, TrayListener {
  void Function()? _close;
  void Function(String)? _action;
  DBusClient? _bus;

  @override
  Future<bool> initialize(
      void Function() close, void Function(String) action) async {
    _close = close;
    _action = action;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    // Intercept close even without a tray, so native work can drain before exit.
    await windowManager.setPreventClose(true);
    trayManager.addListener(this);
    if (Platform.isLinux) _bus = DBusClient.session();
    await trayManager
        .setIcon(Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png');
    await menu('Sync paused: vault locked', canPause: false, paused: true);
    return trayAvailable();
  }

  @override
  Future<bool> trayAvailable() async {
    if (Platform.isWindows) {
      final bounds = await trayManager.getBounds();
      return bounds != null && bounds.width > 0 && bounds.height > 0;
    }
    final watcher = DBusRemoteObject(_bus!,
        name: 'org.kde.StatusNotifierWatcher',
        path: DBusObjectPath('/StatusNotifierWatcher'));
    final value = await watcher
        .getProperty(
            'org.kde.StatusNotifierWatcher', 'IsStatusNotifierHostRegistered')
        .timeout(const Duration(seconds: 1));
    return value.asBoolean();
  }

  @override
  Future<void> menu(String status,
          {required bool canPause, required bool paused}) =>
      trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: 'Open NNTDrive'),
        MenuItem(label: status, disabled: true),
        MenuItem(
            key: 'pause',
            label: paused ? 'Resume sync' : 'Pause sync',
            disabled: !canPause),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit NNTDrive'),
      ]));

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> destroy() async {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {/* Already unavailable. */}
    await _bus?.close();
  }

  @override
  void onWindowClose() => _close?.call();
  @override
  void onTrayIconMouseDown() => _action?.call('open');
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem menuItem) =>
      _action?.call(menuItem.key ?? '');
}
