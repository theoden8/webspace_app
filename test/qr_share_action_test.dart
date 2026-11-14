import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

/// The site settings screen for a site at [url].
Future<void> _settings(WidgetTester tester, {required String url}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(localizedApp(SettingsScreen(
      webViewModel: WebViewModel(initUrl: url),
      appTheme: WebViewTheme.system,
      letGo: () {},
      isolation: fakeContainers(),
    )));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'QR-005: Share QR is offered for a site on the web, not for an imported '
      'file', (tester) async {
    await _settings(tester, url: 'https://example.com/');
    expect(find.text('Share QR'), findsOneWidget);
    await _settings(tester, url: 'file:///Notes.html');
    expect(find.text('Share QR'), findsNothing);
  });

  testWidgets(
      'QR-005: the code draws in its fixed box, and Copy copies the link and '
      'closes', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _settings(tester, url: 'https://example.com/');

    await tester.tap(find.text('Share QR'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'no intrinsic-dimension query reaches the QR view');
    expect(tester.getSize(find.byType(QrImageView)), const Size(240, 240));

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, startsWith('webspace://qr/site/v1/'));
    expect(find.byType(QrImageView), findsNothing, reason: 'the dialog closed');
  });
}
