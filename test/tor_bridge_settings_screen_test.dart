// TOR-016 / LEAK-010: the bridge settings screen.
//
// Two contracts matter most here. The disclosure — the Moat fetch is the one
// outbound seam that deliberately bypasses the proxy, and LEAK-010 requires
// the screen to say so where it is offered rather than bury it in a hint.
// And the paste errors — a bridge line is copied by hand under pressure, so
// a half-copied one must name the missing half instead of "invalid bridge".

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/tor_bridge_settings.dart';
import 'package:webspace/services/tor_bridge_secure_storage.dart';
import 'package:webspace/services/tor_bridges.dart';
import 'package:webspace/services/tor_moat_client.dart';

const _obfs4 =
    'obfs4 192.0.2.10:9443 A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 '
    'cert=abcdEFGH1234ijklMNOP5678qrstUVWX90yzABcdEFghIJklMNop iat-mode=0';

/// 1x1 JPEG, so the captcha path decodes a real image rather than a stub.
const _jpegB64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
    'AAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

class _FakeStore implements FlutterSecureStorage {
  final Map<String, String> store = {};

  @override
  Future<String?> read({required String key, AppleOptions? iOptions,
      AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
      AppleOptions? mOptions, WindowsOptions? wOptions}) async => store[key];

  @override
  Future<void> write({required String key, required String? value,
      AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions,
      WebOptions? webOptions, AppleOptions? mOptions,
      WindowsOptions? wOptions}) async {
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, AppleOptions? iOptions,
      AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
      AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeHttp extends http.BaseClient {
  _FakeHttp(this.handler);
  final http.Response Function(http.Request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = handler(request as http.Request);
    return http.StreamedResponse(
        Stream.value(utf8.encode(res.body)), res.statusCode);
  }
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

void main() {
  Widget host(Widget child) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      );

  testWidgets('the Moat exposure is stated on the screen, not hidden',
      (t) async {
    // LEAK-010: this is the one seam that bypasses the proxy by design, and
    // the requirement is that the user is told where the button is — not in
    // a hint they must open, and not after the fact.
    await t.pumpWidget(host(TorBridgeSettingsScreen(
      storage: TorBridgeSecureStorage(secureStorage: _FakeStore()),
    )));
    await t.pumpAndSettle();

    expect(find.textContaining('without going through Tor'), findsOneWidget);
    expect(find.textContaining('can see that you asked for bridges'),
        findsOneWidget);
    expect(find.textContaining('Pasting a line you obtained elsewhere'),
        findsOneWidget,
        reason: 'the private alternative must be offered alongside');
  });

  testWidgets('a half-copied obfs4 line names the missing half', (t) async {
    await t.pumpWidget(host(TorBridgeSettingsScreen(
      storage: TorBridgeSecureStorage(secureStorage: _FakeStore()),
    )));
    await t.pumpAndSettle();

    // Everything but cert= — the single most common copy/paste truncation.
    await t.enterText(find.byType(TextField).first,
        'obfs4 192.0.2.10:9443 A1B2C3D4E5F6 iat-mode=0');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    expect(find.textContaining('missing its cert='), findsOneWidget,
        reason: 'not a generic "invalid bridge"');
  });

  testWidgets('an unknown transport is refused by name', (t) async {
    await t.pumpWidget(host(TorBridgeSettingsScreen(
      storage: TorBridgeSecureStorage(secureStorage: _FakeStore()),
    )));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).first, '192.0.2.10:9443');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    expect(find.textContaining('must start with obfs4'), findsOneWidget);
  });

  testWidgets('a pasted line is stored, listed, and kept verbatim', (t) async {
    final backing = _FakeStore();
    await t.pumpWidget(host(TorBridgeSettingsScreen(
      storage: TorBridgeSecureStorage(secureStorage: backing),
    )));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).first, _obfs4);
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    expect(find.text(_obfs4), findsOneWidget);
    expect(backing.store['tor_bridges'], contains('192.0.2.10:9443'),
        reason: 'persisted to the keystore, not just held in the widget');
  });

  testWidgets('an unreachable service advises pasting instead', (t) async {
    // On a censored network this is the expected outcome. Reporting it as a
    // service outage would send the user away from the route that works.
    await t.pumpWidget(host(TorBridgeSettingsScreen(
      storage: TorBridgeSecureStorage(secureStorage: _FakeStore()),
      moatClientFactory: () => MoatClient(
        client: _FakeHttp((_) => throw Exception('no route')),
      ),
    )));
    await t.pumpAndSettle();

    await t.tap(find.text('Get bridges automatically'));
    await t.pumpAndSettle();

    expect(find.textContaining('Could not reach the bridge service'),
        findsOneWidget);
    expect(find.textContaining('paste a bridge line obtained another way'),
        findsOneWidget);
  });

  testWidgets('a successful fetch adds the bridges it received', (t) async {
    final backing = _FakeStore();
    await t.pumpWidget(host(TorBridgeSettingsScreen(
      storage: TorBridgeSecureStorage(secureStorage: backing),
      moatClientFactory: () => MoatClient(
        client: _FakeHttp((req) => req.url.path.endsWith('/fetch')
            ? _json({
                'data': [
                  {
                    'transport': ['obfs4'],
                    'image': _jpegB64,
                    'challenge': 'obfs4',
                  }
                ]
              })
            : _json({
                'data': [
                  {'bridges': [_obfs4]}
                ]
              })),
      ),
    )));
    await t.pumpAndSettle();

    await t.tap(find.text('Get bridges automatically'));
    await t.pumpAndSettle();

    // ignore: avoid_print
    expect(find.text(_obfs4), findsOneWidget);
    expect(find.textContaining('Added 1 bridges'), findsOneWidget);
    expect(backing.store['tor_bridges'], contains('192.0.2.10:9443'));
  });

  testWidgets('snowflake says it needs no line rather than looking unset',
      (t) async {
    final backing = _FakeStore();
    backing.store['tor_bridges'] = jsonEncode({
      'enabled': true,
      'transport': 'snowflake',
      'lines': <String>[],
    });
    await t.pumpWidget(host(TorBridgeSettingsScreen(
      storage: TorBridgeSecureStorage(secureStorage: backing),
    )));
    await t.pumpAndSettle();

    expect(find.textContaining('needs no bridge line'), findsOneWidget);
    expect(find.text('No bridge lines added'), findsNothing,
        reason: 'an empty list is correct for snowflake, not a missing step');
  });

  group('message mapping', () {
    testWidgets('every parse error has its own message', (t) async {
      late AppLocalizations loc;
      await t.pumpWidget(host(Builder(builder: (ctx) {
        loc = AppLocalizations.of(ctx);
        return const SizedBox.shrink();
      })));

      final seen = <String>{};
      for (final e in TorBridgeParseError.values) {
        final msg = bridgeParseErrorMessage(loc, e);
        expect(msg, isNotEmpty, reason: '$e');
        expect(seen.add(msg), isTrue,
            reason: '$e reuses another error\'s message, so the user cannot '
                'tell which half of the line is wrong');
      }
    });

    testWidgets('an unreachable Moat is not phrased as a broken service',
        (t) async {
      late AppLocalizations loc;
      await t.pumpWidget(host(Builder(builder: (ctx) {
        loc = AppLocalizations.of(ctx);
        return const SizedBox.shrink();
      })));

      final msg = moatErrorMessage(loc, MoatErrorKind.unreachable);
      expect(msg, contains('expected'),
          reason: 'on a censored network this outcome is normal');
      expect(msg, contains('paste'));
    });
  });
}
