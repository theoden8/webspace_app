// The sidebar's state, one for the app: what each control asks of it.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/controllers/sidebar_controller.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/site_navigation.dart';

void main() {
  late SidebarController sidebar;

  setUp(() async {
    isDemoMode = false;
    SharedPreferences.setMockInitialValues({});
    AppPref.loadAll(await SharedPreferences.getInstance());
    sidebar = SidebarController();
  });

  test('starts open', () {
    expect(sidebar.state, SidebarState.open);
  });

  test('restore returns to the rail it was hidden from', () {
    sidebar
      ..collapse()
      ..hide()
      ..restore();
    expect(sidebar.state, SidebarState.collapsed);
  });

  test('openFully ignores the rail it was hidden from', () {
    sidebar
      ..collapse()
      ..hide()
      ..openFully();
    expect(sidebar.state, SidebarState.open);
  });

  test('restore with nothing to restore opens it', () {
    sidebar.restore();
    expect(sidebar.state, SidebarState.open);
  });

  test('cycle goes open, collapsed, hidden, open (TAB-031)', () {
    final seen = [
      for (var i = 0; i < 3; i++) (sidebar..cycle()).state,
    ];
    expect(seen,
        [SidebarState.collapsed, SidebarState.hidden, SidebarState.open]);
  });

  test('a narrowing window keeps an open sidebar at the rail', () {
    sidebar.narrowed();
    expect(sidebar.state, SidebarState.collapsed);
  });

  test('settle lands where a drag let go, and is persisted', () async {
    sidebar.settle(SidebarState.collapsed);
    expect(sidebar.state, SidebarState.collapsed);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.get(AppPref.sidebarState.key), 'collapsed');
  });
}
