import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dbus/dbus.dart';

import 'package:webspace/platform/host_platform.dart'
    show IOException, hostIsLinux, hostReadFileBytes;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tray_icon.dart';
import 'package:webspace/services/tray_menu_engine.dart';

/// One size of the icon as a StatusNotifierItem carries it: ARGB32 in network
/// byte order, row by row.
typedef SniPixmap = ({int size, Uint8List argb});

const _watcher = 'org.kde.StatusNotifierWatcher';
const _itemInterface = 'org.kde.StatusNotifierItem';
const _menuInterface = 'com.canonical.dbusmenu';
final _itemPath = DBusObjectPath('/StatusNotifierItem');
final _menuPath = DBusObjectPath('/MenuBar');

/// The tray on a Linux desktop: a StatusNotifierItem and its dbusmenu, the
/// D-Bus protocol AppIndicator speaks, registered with the desktop's
/// StatusNotifierWatcher (NOTIF-019). Plasma, Xfce, Cinnamon and Ubuntu's
/// GNOME host one; stock GNOME needs the AppIndicator extension. A watcher
/// that appears later, or comes back after its shell restarts, is registered
/// with as it appears. A Flatpak reaches the watcher only where its manifest
/// lets it talk to the name; otherwise the sandbox answers as a desktop
/// hosting none would, so the log names the permission instead.
class StatusNotifierTray implements TrayIcon {
  StatusNotifierTray({
    required TrayHandlers handlers,
    DBusClient Function()? connect,
    Future<List<SniPixmap>> Function()? pixmaps,
    Future<String?> Function()? sandbox,
  })  : assert(
            hostIsLinux,
            'package:dbus authenticates only on Linux; elsewhere a connection '
            'never opens'),
        _handlers = handlers,
        _connect = connect ?? DBusClient.session,
        _pixmaps = pixmaps ?? _appPixmaps,
        _sandbox = sandbox ?? _flatpakInfo;

  final TrayHandlers _handlers;
  final DBusClient Function() _connect;
  final Future<List<SniPixmap>> Function() _pixmaps;
  final Future<String?> Function() _sandbox;

  /// The connection the icon lives on, or its opening. Closing it is what
  /// takes the icon away: a desktop drops an item whose owner left the bus.
  Future<_Session?>? _session;

  @override
  Future<bool> show(TrayMenu menu) async {
    final session = await (_session ??= _open());
    if (session == null) {
      _session = null;
      return false;
    }
    await session.item.retitle(menu.title);
    await session.menu.update(menu);
    return session.registered;
  }

  @override
  Future<void> remove() async {
    final session = _session;
    _session = null;
    await (await session)?.close();
  }

  Future<_Session?> _open() async {
    final session = _Session(
      _connect(),
      handlers: _handlers,
      pixmaps: await _pixmaps(),
      watcherHidden: _sandboxHides(await _sandbox(), name: _watcher),
    );
    try {
      await session.start();
      return session;
    } on IOException catch (e) {
      LogTag.lifecycle.warning('Tray: no session bus: $e');
      await session.close();
      return null;
    }
  }
}

class _Session {
  _Session(
    this.bus, {
    required TrayHandlers handlers,
    required List<SniPixmap> pixmaps,
    required this.watcherHidden,
  })  : item = _Item(handlers: handlers, pixmaps: pixmaps),
        menu = _Menu(handlers: handlers);

  final DBusClient bus;
  final _Item item;
  final _Menu menu;
  final bool watcherHidden;
  StreamSubscription<DBusNameOwnerChangedEvent>? _watchers;

  /// Whether a watcher holds the icon now.
  var registered = false;

  Future<void> start() async {
    await bus.registerObject(menu);
    await bus.registerObject(item);
    _watchers = bus.nameOwnerChanged
        .where((e) => e.name == _watcher && e.newOwner != null)
        .listen((_) => unawaited(_register()));
    await _register();
  }

  Future<void> _register() async {
    try {
      await bus.callMethod(
        destination: _watcher,
        path: DBusObjectPath('/StatusNotifierWatcher'),
        interface: _watcher,
        name: 'RegisterStatusNotifierItem',
        // A path, not a bus name: the watcher pairs it with this connection,
        // so the icon needs no name of its own (and none in a Flatpak).
        values: [DBusString(_itemPath.value)],
        replySignature: DBusSignature(''),
      );
      registered = true;
      LogTag.lifecycle.debug('Tray: registered with the status notifier watcher');
    } on DBusServiceUnknownException {
      registered = false;
      if (watcherHidden) {
        LogTag.lifecycle.warning('Tray: the Flatpak sandbox hides $_watcher; '
            'its manifest needs --talk-name=$_watcher');
      } else {
        LogTag.lifecycle.debug('Tray: no status notifier watcher yet');
      }
    } on DBusMethodResponseException catch (e) {
      registered = false;
      LogTag.lifecycle.warning('Tray: the watcher refused the icon: ${e.errorName}');
    }
  }

  Future<void> close() async {
    await _watchers?.cancel();
    await bus.close();
  }
}

/// The icon: what a desktop reads to draw it, and a click on it.
class _Item extends DBusObject {
  _Item({required this.handlers, required List<SniPixmap> pixmaps})
      : _pixmaps = _pixmapArray(pixmaps),
        super(_itemPath);

  final TrayHandlers handlers;
  final DBusArray _pixmaps;
  var _title = '';

  Future<void> retitle(String title) async {
    if (title == _title) return;
    _title = title;
    await emitSignal(_itemInterface, 'NewTitle');
    await emitSignal(_itemInterface, 'NewToolTip');
  }

  Map<String, DBusValue> get _properties => {
        'Category': const DBusString('ApplicationStatus'),
        'Id': const DBusString('webspace'),
        'Title': DBusString(_title),
        'Status': const DBusString('Active'),
        'IconName': const DBusString(''),
        'IconPixmap': _pixmaps,
        'OverlayIconName': const DBusString(''),
        'OverlayIconPixmap': _pixmapArray(const []),
        'AttentionIconName': const DBusString(''),
        'AttentionIconPixmap': _pixmapArray(const []),
        'AttentionMovieName': const DBusString(''),
        'ToolTip': DBusStruct([
          const DBusString(''),
          _pixmapArray(const []),
          DBusString(_title),
          const DBusString(''),
        ]),
        // A click shows the window; the menu opens on a right click.
        'ItemIsMenu': const DBusBoolean(false),
        'Menu': _menuPath,
      };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != _itemInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = _properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
          interface == _itemInterface ? _properties : const {});

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _itemInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'Activate':
        handlers.pressed(const TrayShow());
      case 'SecondaryActivate' || 'ContextMenu' || 'Scroll':
        break;
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }
}

/// The icon's menu, as dbusmenu lays it out: one level under the root.
class _Menu extends DBusObject {
  _Menu({required this.handlers}) : super(_menuPath);

  final TrayHandlers handlers;
  TrayMenu? _menu;
  var _revision = 0;

  static final _properties = <String, DBusValue>{
    'Version': const DBusUint32(3),
    'TextDirection': const DBusString('ltr'),
    'Status': const DBusString('normal'),
    'IconThemePath': DBusArray.string(const []),
  };

  Future<void> update(TrayMenu menu) async {
    _menu = menu;
    _revision++;
    await emitSignal(_menuInterface, 'LayoutUpdated',
        [DBusUint32(_revision), const DBusInt32(0)]);
  }

  TrayEntry? _entry(int id) {
    for (final entry in _menu?.entries ?? const <TrayEntry>[]) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  static Map<String, DBusValue> _propertiesOf(TrayEntry entry) =>
      switch (entry) {
        // dbusmenu reads one underscore as a mnemonic and two as one.
        TrayItem(:final label, :final action) => {
            'label': DBusString(label.replaceAll('_', '__')),
            // The key the window answers (NAV-014), shown beside the line.
            if (action is TrayQuit)
              'shortcut': DBusArray(DBusSignature('as'), [
                DBusArray.string(const ['Control', 'q']),
              ]),
          },
        TraySeparator() => {'type': const DBusString('separator')},
      };

  static DBusStruct _node(TrayEntry entry) => DBusStruct([
        DBusInt32(entry.id),
        DBusDict.stringVariant(_propertiesOf(entry)),
        DBusArray.variant(const []),
      ]);

  DBusStruct _root() => DBusStruct([
        const DBusInt32(0),
        DBusDict.stringVariant({'children-display': const DBusString('submenu')}),
        DBusArray.variant([
          for (final entry in _menu?.entries ?? const <TrayEntry>[])
            _node(entry),
        ]),
      ]);

  /// Whether bringing the menu up to date before it opens changed it.
  Future<bool> _opening() async {
    final before = _revision;
    await handlers.opening();
    return _revision != before;
  }

  void _event(int id, {required String event}) {
    if (event != 'clicked') return;
    if (_menu?.actionOf(id) case final action?) handlers.pressed(action);
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != _menuInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = _properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
          interface == _menuInterface ? _properties : const {});

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _menuInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch ((methodCall.name, methodCall.values)) {
      case ('GetLayout', [DBusInt32(value: final parent), DBusInt32(), DBusArray()]):
        final node = parent == 0
            ? _root()
            : switch (_entry(parent)) { final entry? => _node(entry), null => null };
        if (node == null) return DBusMethodErrorResponse.invalidArgs('no item $parent');
        return DBusMethodSuccessResponse([DBusUint32(_revision), node]);
      case ('GetGroupProperties', [DBusArray(:final children), DBusArray()]):
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in children)
              if (id case DBusInt32(:final value))
                if (_entry(value) case final entry?)
                  DBusStruct([
                    DBusInt32(value),
                    DBusDict.stringVariant(_propertiesOf(entry)),
                  ]),
          ]),
        ]);
      case ('GetProperty', [DBusInt32(:final value), DBusString(value: final name)]):
        final property = switch (_entry(value)) {
          final entry? => _propertiesOf(entry)[name],
          null => null,
        };
        return property == null
            ? DBusMethodErrorResponse.invalidArgs('no property $name on $value')
            : DBusMethodSuccessResponse([DBusVariant(property)]);
      case ('Event', [DBusInt32(:final value), DBusString(value: final event), _, _]):
        _event(value, event: event);
        return DBusMethodSuccessResponse();
      case ('EventGroup', [DBusArray(:final children)]):
        final missing = <int>[];
        for (final child in children) {
          if (child case DBusStruct(children: [DBusInt32(:final value), DBusString(value: final event), _, _])) {
            if (_entry(value) == null) {
              missing.add(value);
            } else {
              _event(value, event: event);
            }
          }
        }
        return DBusMethodSuccessResponse([DBusArray.int32(missing)]);
      case ('AboutToShow', [DBusInt32()]):
        return DBusMethodSuccessResponse([DBusBoolean(await _opening())]);
      case ('AboutToShowGroup', [DBusArray()]):
        final changed = await _opening();
        return DBusMethodSuccessResponse([
          DBusArray.int32(changed ? const [0] : const []),
          DBusArray.int32(const []),
        ]);
      case ('GetLayout' || 'GetGroupProperties' || 'GetProperty' || 'Event' ||
            'EventGroup' || 'AboutToShow' || 'AboutToShowGroup', _):
        return DBusMethodErrorResponse.invalidArgs();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}

/// What a Flatpak's sandbox grants, which it mounts at the root; elsewhere
/// there is none.
Future<String?> _flatpakInfo() async {
  try {
    return utf8.decode(await hostReadFileBytes('/.flatpak-info'),
        allowMalformed: true);
  } on IOException {
    return null;
  }
}

/// Whether the sandbox [info] describes keeps [name] from the app: its bus
/// proxy answers a call to a name it may not talk to as if nothing owned it,
/// and never reports the name appearing. Talking needs the whole bus
/// (`--socket=session-bus`), or talk or own on the name or a `.*` above it.
bool _sandboxHides(String? info, {required String name}) {
  if (info == null) return false;
  var section = '';
  for (final line in const LineSplitter().convert(info)) {
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1);
    }
    switch ((section, line.split('='))) {
      case ('Context', ['sockets', final sockets])
          when sockets.split(';').contains('session-bus'):
        return false;
      case ('Session Bus Policy', [final granted, 'talk' || 'own'])
          when granted == name ||
              granted.endsWith('.*') &&
                  '$name.'.startsWith(granted.substring(0, granted.length - 1)):
        return false;
    }
  }
  return true;
}

DBusArray _pixmapArray(List<SniPixmap> pixmaps) =>
    DBusArray(DBusSignature('(iiay)'), [
      for (final p in pixmaps)
        DBusStruct([DBusInt32(p.size), DBusInt32(p.size), DBusArray.byte(p.argb)]),
    ]);

/// The app's round icon, which the launcher shows too, at the sizes panels
/// draw a status icon at.
Future<List<SniPixmap>> _appPixmaps() async {
  final images = await trayGlyphs('assets/webspace_icon_round.png',
      sizes: const [16, 22, 24, 32, 48, 64]);
  return [
    for (final image in images)
      if (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba)
          case final rgba?)
        (size: image.width, argb: _argb(rgba)),
  ];
}

Uint8List _argb(ByteData rgba) {
  final argb = Uint8List(rgba.lengthInBytes);
  for (var i = 0; i < argb.length; i += 4) {
    argb[i] = rgba.getUint8(i + 3);
    argb[i + 1] = rgba.getUint8(i);
    argb[i + 2] = rgba.getUint8(i + 1);
    argb[i + 3] = rgba.getUint8(i + 2);
  }
  return argb;
}
