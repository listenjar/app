// The tray icon (the macOS menu bar, Windows' notification area): ListenJar
// keeps syncing after its window closes. Closing the window only hides it,
// and on macOS its Dock icon with it; the tray says how the sync is going,
// brings the window back, syncs now, or quits. Quitting is the only way the
// sync stops. It shows the account and the feeds (account.dart, feeds.dart), with or
// without a window.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Listenable;
import 'package:nativeapi/nativeapi.dart' as native show Size;
import 'package:nativeapi_flutter/nativeapi_flutter.dart';

import 'account.dart';
import 'feeds.dart';

final class Tray {
  Tray._(this._account, this._feeds, this._icon, this._menu, this._status, this._syncNow);

  final Account _account;
  final Feeds _feeds;
  late final _shownFrom = Listenable.merge([_account, _feeds]);

  /// What the menu shows now, so an unchanged sync touches no native item.
  (String, bool)? _shown;

  /// The app's window, once the system has one to give (not yet while the
  /// first frame is being built).
  Window? _window;
  Timer? _finding;
  final TrayIcon _icon;

  // Held so the native menu and its items live as long as the tray.
  final Menu _menu;
  final MenuItem _status;
  final MenuItem _syncNow;

  /// Puts the icon in the tray and keeps the window from closing, on macOS
  /// and Windows; null elsewhere, or when the system has no tray for it.
  static Tray? start(Account account, Feeds feeds) {
    if (!Platform.isMacOS && !Platform.isWindows) return null;
    final icon = TrayIcon.create();
    final menu = Menu.create();
    if (icon == null || menu == null) return null;

    MenuItem item(String label, [void Function()? onClick]) {
      final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal)!;
      if (onClick == null) {
        item.isEnabled = false;
      } else {
        item.addListener((event) {
          if (event is MenuItemClickedEvent) onClick();
        });
      }
      return item;
    }

    late final Tray tray;
    final status = item('ListenJar');
    final syncNow = item('Sync now', feeds.syncNow);
    menu
      ..addItem(status)
      ..addSeparator()
      ..addItem(item('Open ListenJar', () => tray.show()))
      ..addItem(syncNow)
      ..addSeparator()
      ..addItem(item('Quit ListenJar', () => Application.instance.quit(0)));

    if (Platform.isMacOS) {
      // A template image: the menu bar tints it for light, dark and selected.
      icon
        ..icon = ImageAsset.fromAsset('assets/tray/template.png')
        ..isIconTemplate = true
        ..iconSize = const native.Size(width: 18, height: 18);
    } else {
      icon.icon = ImageAsset.fromAsset('assets/tray/tile.png');
    }
    icon
      ..setTooltip('ListenJar')
      ..setContextMenu(menu)
      // A menu-bar icon opens its menu on a click; a Windows one opens the
      // window, its menu on a right click.
      ..setContextMenuTrigger(Platform.isMacOS ? ContextMenuTrigger.clicked : ContextMenuTrigger.rightClicked)
      ..setVisible(true);

    tray = Tray._(account, feeds, icon, menu, status, syncNow);
    icon.addListener((event) {
      if (event is TrayIconClickedEvent && !Platform.isMacOS) tray.show();
    });
    tray._findWindow();
    tray._shownFrom.addListener(tray._update);
    tray._update();
    return tray;
  }

  /// Takes over the window's close button once the window is there.
  void _findWindow([int attempt = 0]) {
    final window = Application.instance.getPrimaryWindow() ?? WindowManager.instance.getCurrent();
    if (window == null) {
      if (attempt < 100) _finding = Timer(const Duration(milliseconds: 100), () => _findWindow(attempt + 1));
      return;
    }
    _window = window;
    window.addListener((event) {
      if (event is WindowCloseRequestedEvent) {
        event.request.cancel();
        _hide();
      }
    });
  }

  /// The menu's first line says how the sync is going; "Sync now" needs an
  /// account.
  void _update() {
    final shown = (_feeds.summary, _account.user != null);
    if (shown == _shown) return;
    _shown = shown;
    final (status, canSync) = shown;
    _status.label = status;
    _syncNow.isEnabled = canSync;
    _icon.setTooltip('ListenJar: $status');
  }

  /// Brings the window back, in front, with its Dock icon.
  void show() {
    if (Platform.isMacOS) Application.instance.setDockIconVisible(true);
    _window
      ?..show()
      ..focus();
  }

  void _hide() {
    _window?.hide();
    if (Platform.isMacOS) Application.instance.setDockIconVisible(false);
  }

  void dispose() {
    _shownFrom.removeListener(_update);
    _finding?.cancel();
    _icon
      ..setVisible(false)
      ..dispose();
    _menu.dispose();
  }
}
