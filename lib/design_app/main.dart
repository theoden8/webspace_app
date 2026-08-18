// Designer entrypoint: the real app, in a browser, with demo data.
//
// This is lib/main.dart's WebSpaceApp — the same widgets, navigation and
// animations the app ships — seeded with demo sites and webspaces so there is
// something to move around in, and with persistence disabled so nothing a
// designer does leaks into real state.
//
//   flutter run -d web-server --web-port 8110 -t lib/design_app/main.dart
//   fvm flutter build web -t lib/design_app/main.dart --no-web-resources-cdn
//
// Design values live in lib/theme/design_tokens.dart and
// lib/theme/accent_theme.dart; edit those and hot reload.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/demo_data.dart';
import 'package:webspace/main.dart' as app;

/// CanvasKit pulls Roboto from fonts.gstatic.com; where that is unreachable it
/// draws no text at all. Serve it from web/fonts (see sync_fonts.js) instead.
Future<void> _loadRoboto() async {
  const faces = ['Roboto_400Regular', 'Roboto_500Medium', 'Roboto_700Bold'];
  final loader = FontLoader('Roboto');
  var loaded = 0;
  for (final face in faces) {
    try {
      final res = await http.get(Uri.parse('fonts/$face.ttf'));
      if (res.statusCode != 200) continue;
      loader.addFont(Future.value(ByteData.sublistView(res.bodyBytes)));
      loaded++;
    } catch (_) {}
  }
  if (loaded > 0) await loader.load();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadRoboto();

  // Seed before the app reads prefs, and keep isDemoMode on so no write path
  // persists: a designer clicking around never changes stored state. On web
  // the prefs backend is localStorage, so a reload starts from the seed again
  // only after a clear; isDemoMode is what keeps writes out.
  isDemoMode = true;
  await seedDemoData(theme: Uri.base.queryParameters['theme'] ?? 'system');

  runApp(app.WebSpaceApp());
}
