// Designer entrypoint: the real app, in a browser, with demo data.
//
// This is lib/main.dart's WebSpaceApp — the same widgets, navigation and
// animations the app ships — seeded with demo sites and webspaces so there is
// something to move around in.
//
// Persistence stays ON. On web that is the browser origin's localStorage, so a
// designer's changes survive a reload and the app behaves like the app; it
// cannot reach a device's real state. Seeding therefore runs only when the
// store is empty, otherwise a reload would overwrite whatever they did.
// To start over, clear site data for the origin.
//
//   flutter run -d web-server --web-port 8110 -t lib/design_app/main.dart
//   fvm flutter build web -t lib/design_app/main.dart --no-web-resources-cdn
//
// Design values live in lib/theme/design_tokens.dart and
// lib/theme/accent_theme.dart; edit those and hot reload.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:shared_preferences/shared_preferences.dart';

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

  final prefs = await SharedPreferences.getInstance();
  final seeded = (prefs.getStringList('webViewModels') ?? const []).isNotEmpty;
  if (!seeded) {
    await seedDemoData(theme: Uri.base.queryParameters['theme'] ?? 'system');
  }
  // Counters for the protection report, so its shield carries a badge and the
  // report has a week to draw. Session-only: nothing here is flushed.
  seedDemoBlockStats();

  runApp(app.WebSpaceApp());
}
