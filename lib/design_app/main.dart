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

import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/demo_data.dart';
import 'package:webspace/app.dart';
import 'package:webspace/design_gallery/roboto.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/webview.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadRoboto();

  final prefs = await SharedPreferences.getInstance();
  final seeded = (prefs.getStringList('webViewModels') ?? const []).isNotEmpty;
  if (!seeded) {
    await seedDemoData(theme: Uri.base.queryParameters['theme'] ?? 'system');
  }
  // Counters for the protection report, so its shield carries a badge and the
  // report has a week to draw. Session-only: nothing here is flushed.
  seedDemoBlockStats();
  await GlobalOutboundProxy.initialize();
  // The web build draws no webview; the mode any settings builder reads.
  WebViewFactory.hybridComposition = true;

  runApp(const WebSpaceApp(launch: ProcessLaunch.user));
}
