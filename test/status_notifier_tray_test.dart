// The StatusNotifierItem tray runs on Linux only, and package:dbus
// authenticates nowhere else: on macOS a connection never opens.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/status_notifier_tray.dart';
import 'package:webspace/services/tray_menu_engine.dart';
import 'package:webspace/settings/site_ids.dart';

/// NOTIF-019 on Linux: the tray speaks StatusNotifierItem and dbusmenu to a
/// desktop that hosts them. A private message bus stands in for the session
/// bus, and a client on it plays the desktop: it owns the watcher's name,
/// records the registration and reads and clicks the menu as Plasma or the
/// AppIndicator extension does.
void main() {
  const labels = (title: 'WebSpace', show: 'Show WebSpace', quit: 'Quit WebSpace');
  final chat = SiteId('chat');

  late Directory dir;
  late DBusServer server;
  late DBusAddress address;
  late DBusClient desktop;
  late _Watcher watcher;
  late List<TrayAction> pressed;
  late Future<void> Function() opening;
  late StatusNotifierTray tray;

  Future<void> hostWatcher() async {
    await desktop.registerObject(watcher);
    await desktop.requestName('org.kde.StatusNotifierWatcher');
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sni_test');
    server = DBusServer();
    address = await server.listenAddress(DBusAddress.unix(dir: dir));
    desktop = DBusClient(address);
    watcher = _Watcher();
    pressed = [];
    opening = () async {};
    tray = StatusNotifierTray(
      handlers: (pressed: pressed.add, opening: () => opening()),
      connect: () => DBusClient(address),
      pixmaps: () async => [(size: 2, argb: Uint8List.fromList(List.filled(16, 7)))],
    );
  });

  tearDown(() async {
    await tray.remove();
    await desktop.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  Future<void> until(FutureOr<bool> Function() done,
      {required String what}) async {
    for (var i = 0; i < 200 && !await done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await done(), isTrue, reason: 'timed out waiting for $what');
  }

  DBusRemoteObject item() => DBusRemoteObject(desktop,
      name: watcher.registered.single.sender,
      path: DBusObjectPath(watcher.registered.single.path));

  DBusRemoteObject menuOf(DBusObjectPath path) => DBusRemoteObject(desktop,
      name: watcher.registered.single.sender, path: path);

  /// The menu as a desktop lays it out: each line's id and its properties.
  Future<List<(int, Map<String, DBusValue>)>> layout(DBusRemoteObject menu) async {
    final reply = await menu.callMethod('com.canonical.dbusmenu', 'GetLayout',
        [const DBusInt32(0), const DBusInt32(-1), DBusArray.string(const [])],
        replySignature: DBusSignature('u(ia{sv}av)'));
    final root = reply.values[1].asStruct();
    return [
      for (final child in root[2].asArray())
        (
          child.asVariant().asStruct()[0].asInt32(),
          child.asVariant().asStruct()[1].asStringVariantDict(),
        ),
    ];
  }

  String? labelOf((int, Map<String, DBusValue>) line) =>
      line.$2['label']?.asString();

  TrayMenu menuWith(List<TraySite> sites) =>
      TrayMenus().build(labels: labels, sites: sites);

  test('NOTIF-019 the icon registers with the desktop and serves its picture, '
      'name and menu', () async {
    await hostWatcher();
    final shown = await tray.show(menuWith([(id: chat, name: 'Chat', unread: 3)]));

    expect(shown, isTrue);
    expect(watcher.registered.single.path, '/StatusNotifierItem');
    final properties =
        await item().getAllProperties('org.kde.StatusNotifierItem');
    expect(properties['Title']?.asString(), 'WebSpace');
    expect(properties['Status']?.asString(), 'Active');
    expect(properties['ItemIsMenu']?.asBoolean(), isFalse,
        reason: 'a click shows the window; the menu is the right click');
    final pixmap = properties['IconPixmap']!.asArray().single.asStruct();
    expect([pixmap[0].asInt32(), pixmap[1].asInt32(), pixmap[2].asByteArray().length],
        [2, 2, 16]);

    final menu = menuOf(properties['Menu']!.asObjectPath());
    expect((await layout(menu)).map(labelOf),
        ['Show WebSpace', null, 'Chat (3)', null, 'Quit WebSpace']);
    final quit = (await layout(menu)).last.$2['shortcut']!.asArray();
    expect(quit.single.asStringArray(), ['Control', 'q']);
  });

  test('NOTIF-019 a click on the icon and on each line asks for what it says',
      () async {
    await hostWatcher();
    await tray.show(menuWith([(id: chat, name: 'Chat', unread: null)]));
    final properties =
        await item().getAllProperties('org.kde.StatusNotifierItem');
    final menu = menuOf(properties['Menu']!.asObjectPath());

    await item().callMethod('org.kde.StatusNotifierItem', 'Activate',
        [const DBusInt32(0), const DBusInt32(0)]);
    final lines = await layout(menu);
    for (final label in ['Chat', 'Quit WebSpace']) {
      final id = lines.firstWhere((l) => labelOf(l) == label).$1;
      await menu.callMethod('com.canonical.dbusmenu', 'Event', [
        DBusInt32(id),
        const DBusString('clicked'),
        const DBusVariant(DBusInt32(0)),
        const DBusUint32(0),
      ]);
    }

    expect(pressed, [
      isA<TrayShow>(),
      isA<TrayOpenSite>().having((a) => a.site, 'site', chat),
      isA<TrayQuit>(),
    ]);
  });

  test('NOTIF-019 the menu is brought up to date as it opens', () async {
    await hostWatcher();
    final menus = TrayMenus();
    await tray.show(menus.build(
        labels: labels, sites: [(id: chat, name: 'Chat', unread: null)]));
    opening = () async {
      await tray.show(menus.build(
          labels: labels, sites: [(id: chat, name: 'Chat', unread: 5)]));
    };
    final properties =
        await item().getAllProperties('org.kde.StatusNotifierItem');
    final menu = menuOf(properties['Menu']!.asObjectPath());

    final reply = await menu.callMethod(
        'com.canonical.dbusmenu', 'AboutToShow', [const DBusInt32(0)],
        replySignature: DBusSignature('b'));

    expect(reply.values.single.asBoolean(), isTrue,
        reason: 'the desktop reads the menu again only when told it changed');
    expect((await layout(menu)).map(labelOf), contains('Chat (5)'));
  });

  test('NOTIF-019 a desktop that starts hosting icons later gets this one',
      () async {
    expect(await tray.show(menuWith(const [])), isFalse,
        reason: 'no watcher yet: nowhere to show it');

    await hostWatcher();

    await until(() => watcher.registered.isNotEmpty,
        what: 'the icon to register with the watcher that appeared');
  });

  test('NOTIF-019 removing the icon takes it off the bus, which is how a '
      'desktop drops it', () async {
    await hostWatcher();
    await tray.show(menuWith(const []));
    final owner = watcher.registered.single.sender;
    expect(await desktop.nameHasOwner(owner), isTrue);

    await tray.remove();

    await until(() async => !await desktop.nameHasOwner(owner),
        what: "the icon's connection to leave the bus");
  });

  test("a site's underscore is not read as a mnemonic", () async {
    await hostWatcher();
    await tray.show(menuWith([(id: chat, name: 'my_site', unread: null)]));
    final properties =
        await item().getAllProperties('org.kde.StatusNotifierItem');
    final menu = menuOf(properties['Menu']!.asObjectPath());

    expect((await layout(menu)).map(labelOf), contains('my__site'));
  });

  test('without a session bus there is no tray, and nothing throws', () async {
    final orphan = StatusNotifierTray(
      handlers: (pressed: pressed.add, opening: () async {}),
      connect: () =>
          DBusClient(DBusAddress.unix(path: '${dir.path}/no_such_bus')),
      pixmaps: () async => const [],
    );

    expect(await orphan.show(menuWith(const [])), isFalse);
    await orphan.remove();
  });
}

/// The desktop's StatusNotifierWatcher: who registered which item.
class _Watcher extends DBusObject {
  _Watcher() : super(DBusObjectPath('/StatusNotifierWatcher'));

  final registered = <({String sender, String path})>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.kde.StatusNotifierWatcher' &&
        methodCall.name == 'RegisterStatusNotifierItem') {
      registered.add((
        sender: methodCall.sender!,
        path: methodCall.values.single.asString(),
      ));
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}
