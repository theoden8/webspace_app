// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/app_privacy.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/outbound_http.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/fake_path_provider.dart';
import 'helpers/localized.dart';

/// LCDN-009: App Settings' LocalCDN row downloads the popular set with its
/// progress, then names the count, size and date, and clears it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final service = LocalCdnService.instance;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('localcdn_row');
    PathProviderPlatform.instance = FakePathProvider(dir);
    SharedPreferences.setMockInitialValues({});
    await service.initialize();
  });
  tearDownAll(() => dir.delete(recursive: true));
  tearDown(resetOutboundHttp);

  /// Runs real I/O (the cache's files) until [done] holds.
  Future<void> until(WidgetTester tester, {required bool Function() done}) =>
      tester.runAsync(() async {
        for (var i = 0; i < 500 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(done(), isTrue);
      });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('LCDN-009: download with progress, the cache named, then cleared',
      (tester) async {
    final gate = Completer<void>();
    final fetches = FakeOutbound(responder: (request) async {
      if (gate.isCompleted == false && service.resourceCount >= 1) {
        await gate.future;
      }
      return http.Response(request.url.path, 200);
    });
    outboundHttp = fetches;

    await tester.runAsync(() => tester.pumpWidget(
        localizedApp(const Scaffold(body: LocalCdnTile()))));
    await settle(tester);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    await tester.runAsync(() => tester.tap(find.byIcon(Icons.download)));
    await until(tester, done: () => fetches.requests.length >= 2);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Downloading 1/\d+\.\.\.$')),
        findsOneWidget);

    gate.complete();
    await until(tester, done: () => fetches.requests.length > 2 &&
        service.resourceCount == fetches.requests.length);
    await settle(tester);
    await settle(tester);
    final count = service.resourceCount;
    expect(count, greaterThan(1));
    expect(find.textContaining(RegExp('^$count resources \\(.+\\)\$')),
        findsOneWidget);
    expect(find.textContaining('Updated: '), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);

    await tester.runAsync(() => tester.tap(find.byIcon(Icons.delete_outline)));
    await until(tester, done: () => service.resourceCount == 0);
    await settle(tester);
    await settle(tester);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });
}
