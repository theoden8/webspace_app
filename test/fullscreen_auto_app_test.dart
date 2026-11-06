import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

void main() {
  testWidgets('activating a fullscreenMode site hides the AppBar (FS-003)',
      (tester) async {
    await pumpRealApp(tester, sites: [
      WebViewModel(initUrl: 'https://plain.test', name: 'Plain'),
      WebViewModel(
        initUrl: 'https://immersive.test',
        name: 'Immersive',
        fullscreenMode: true,
      ),
    ]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Plain');
    expect(find.byType(AppBar), findsWidgets,
        reason: 'a site without fullscreenMode keeps the app bar');

    await openSiteFromDrawer(tester, name: 'Immersive');
    expect(find.byType(AppBar), findsNothing);
  });
}
