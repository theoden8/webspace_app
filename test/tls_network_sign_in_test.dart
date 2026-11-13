import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/network_sign_in.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/services/webview_tls.dart';
import 'package:webspace/widgets/untrusted_cert_prompt.dart';

import 'helpers/localized.dart';
import 'helpers/host_hooks.dart';

/// A certificate as the platform hands it over: a Wi-Fi sign-in page's
/// (an Aruba controller's) unless named otherwise, with [der] standing in
/// for its bytes, which only the fingerprint reads.
inapp.SslCertificate _cert({
  String issuedTo = 'securelogin.arubanetworks.com',
  List<int>? der = const [1, 2, 3],
}) =>
    inapp.SslCertificate(
      issuedTo: inapp.SslCertificateDName(CName: issuedTo),
      issuedBy: inapp.SslCertificateDName(CName: 'Aruba7205-US-CS0017070'),
      x509Certificate: der == null
          ? null
          : (inapp.X509Certificate()..encoded = Uint8List.fromList(der)),
    );

inapp.ServerTrustChallenge _challenge(String host,
        {required inapp.SslCertificate cert}) =>
    inapp.ServerTrustChallenge(
      protectionSpace: inapp.URLProtectionSpace(
          host: host, protocol: 'https', port: 443, sslCertificate: cert),
    );

/// The host's answers, recording what the user was shown.
class _Host {
  _Host({required this.trust});

  Future<bool> Function() trust;
  final asked = <String>[];
  final told = <SignInNotice>[];

  WebViewHostHooks get hooks => inertHostHooks(untrustedCertificate: (host, {required port, required certificate}) {
          asked.add(host);
          return trust();
        }, networkSignIn: (notice) async => told.add(notice),);
}

void main() {
  late NetworkVerdict verdict;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await TrustedHostsService.instance.clear();
    WebViewTls.resetForTest();
    verdict = const NoSignIn();
    NetworkSignIn.instance = NetworkSignIn(read: () async => verdict);
  });

  /// A rejected handshake as Android and Linux deliver it, after the OS's
  /// verdict, whatever host runs the test.
  Future<inapp.ServerTrustAuthResponseAction?> answer(
    String host, {
    required WebViewHostHooks? hooks,
    inapp.SslCertificate? cert,
  }) async {
    final response = await WebViewTls.handleServerTrust(null,
        challenge: _challenge(host, cert: cert ?? _cert()),
        hooks: hooks,
        apple: false);
    return response?.action;
  }

  group('TLS-012 a network that wants a sign-in', () {
    test('asks about no certificate, and says so once per network', () async {
      verdict = SignInRequired(NetworkKey.android('100'));
      final host = _Host(trust: () async => true);
      for (final name in ['discord.com', 'cdn.discordapp.com', 'discord.com']) {
        expect(await answer(name, hooks: host.hooks),
            inapp.ServerTrustAuthResponseAction.CANCEL);
      }
      expect(host.asked, isEmpty);
      expect(host.told,
          [(host: 'discord.com', answeredAs: 'securelogin.arubanetworks.com')]);

      verdict = SignInRequired(NetworkKey.android('101'));
      await answer('discord.com', hooks: host.hooks);
      expect(host.told, hasLength(2), reason: 'a reconnect is a new network');
    });

    test('pins nothing, and lets no earlier pin through', () async {
      final fingerprint =
          TrustedHostsService.fingerprintFromInappCertificate(_cert())!;
      await TrustedHostsService.instance
          .trust(host: 'discord.com', port: 443, fingerprint: fingerprint);
      verdict = SignInRequired(NetworkKey.android('100'));
      final host = _Host(trust: () async => true);
      expect(await answer('discord.com', hooks: host.hooks),
          inapp.ServerTrustAuthResponseAction.CANCEL);
      expect(TrustedHostsService.instance.all(), hasLength(1));
    });

    test('a portal reported while the prompt is open pins nothing and '
        'lets nothing through', () async {
      // The verdict was read before the prompt; the user's Accept lands
      // after the OS starts reporting a portal (tls_trust.tla).
      final host = _Host(trust: () async {
        verdict = SignInRequired(NetworkKey.android('100'));
        return true;
      });
      expect(await answer('discord.com', hooks: host.hooks),
          inapp.ServerTrustAuthResponseAction.CANCEL);
      expect(host.asked, ['discord.com']);
      expect(TrustedHostsService.instance.all(), isEmpty);
      expect(host.told, hasLength(1));
    });

    test('so does the load error path\'s', () async {
      await answer('discord.com', hooks: null);
      final host = _Host(trust: () async {
        verdict = SignInRequired(NetworkKey.networkManager('/active/4'));
        return true;
      });
      expect(
          await WebViewTls.handleSslLoadError(
              view: null,
              url: 'https://discord.com/app',
              hooks: host.hooks,
              apple: false),
          isFalse);
      expect(host.asked, ['discord.com']);
      expect(TrustedHostsService.instance.all(), isEmpty);
    });

    test('the load error path neither asks nor reloads', () async {
      verdict = SignInRequired(NetworkKey.networkManager('/active/3'));
      final host = _Host(trust: () async => true);
      expect(
          await WebViewTls.handleSslLoadError(
              view: null,
              url: 'https://discord.com/app',
              hooks: host.hooks,
              apple: false),
          isFalse);
      expect(host.asked, isEmpty);
      expect(host.told, hasLength(1));
    });

    test('on iOS and macOS the OS decides, and none of it runs', () async {
      var read = false;
      NetworkSignIn.instance = NetworkSignIn(read: () async {
        read = true;
        return SignInRequired(NetworkKey.android('100'));
      });
      final host = _Host(trust: () async => true);
      final response = await WebViewTls.handleServerTrust(null,
          challenge: _challenge('discord.com', cert: _cert()),
          hooks: host.hooks,
          apple: true);
      expect(response, isNull, reason: 'null defers the verdict to the OS');
      expect(
          await WebViewTls.handleSslLoadError(
              view: null,
              url: 'https://discord.com/app',
              hooks: host.hooks,
              apple: true),
          isFalse);
      expect(read, isFalse);
      expect(host.asked, isEmpty);
      expect(host.told, isEmpty);
    });

    test('a webview no one sees keeps the notice for one that is', () async {
      verdict = SignInRequired(NetworkKey.android('100'));
      expect(await answer('discord.com', hooks: null),
          inapp.ServerTrustAuthResponseAction.CANCEL);
      final host = _Host(trust: () async => true);
      await answer('discord.com', hooks: host.hooks);
      expect(host.told, hasLength(1));
    });

    test('once signed in, the certificate is asked about again', () async {
      verdict = SignInRequired(NetworkKey.android('100'));
      final host = _Host(trust: () async => false);
      await answer('self-signed.example', hooks: host.hooks);
      verdict = const NoSignIn();
      await answer('self-signed.example', hooks: host.hooks);
      expect(host.asked, ['self-signed.example']);
    });
  });

  testWidgets('TLS-012 the notice names the site and the page that answered',
      (tester) async {
    await pumpLocalized(tester,
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () => showNetworkSignIn(context,
                    notice: (
                      host: 'discord.com',
                      answeredAs: 'securelogin.arubanetworks.com'
                    )),
                child: const Text('open'))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to the network'), findsOneWidget);
    expect(find.textContaining('discord.com'), findsOneWidget);
    expect(find.text('securelogin.arubanetworks.com'), findsOneWidget);
    expect(find.text('Trust this site'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to the network'), findsNothing);
  });

  group('TLS-013 a declined certificate', () {
    test('is not asked about again in this run, for any host', () async {
      final host = _Host(trust: () async => false);
      for (final name in ['discord.com', 'cdn.discordapp.com', 'discord.com']) {
        expect(await answer(name, hooks: host.hooks),
            inapp.ServerTrustAuthResponseAction.CANCEL);
      }
      expect(host.asked, ['discord.com']);

      await answer('discord.com',
          hooks: host.hooks, cert: _cert(issuedTo: 'other', der: [4, 5, 6]));
      expect(host.asked, ['discord.com', 'discord.com'],
          reason: 'another certificate is another question');
    });

    test('is asked about once at a time', () async {
      final reply = Completer<bool>();
      final host = _Host(trust: () => reply.future);
      final first = answer('discord.com', hooks: host.hooks);
      expect(await answer('cdn.discordapp.com', hooks: host.hooks),
          inapp.ServerTrustAuthResponseAction.CANCEL);
      reply.complete(false);
      expect(await first, inapp.ServerTrustAuthResponseAction.CANCEL);
      expect(host.asked, ['discord.com']);
    });

    test('without its bytes, is remembered for its host alone', () async {
      final host = _Host(trust: () async => false);
      await answer('a.example', hooks: host.hooks, cert: _cert(der: null));
      await answer('a.example', hooks: host.hooks, cert: _cert(der: null));
      await answer('b.example', hooks: host.hooks, cert: _cert(der: null));
      expect(host.asked, ['a.example', 'b.example']);
    });

    test('an approved one is pinned for its host', () async {
      final host = _Host(trust: () async => true);
      expect(await answer('self-signed.example', hooks: host.hooks),
          inapp.ServerTrustAuthResponseAction.PROCEED);
      expect(
          TrustedHostsService.instance.isTrusted(
              host: 'self-signed.example',
              port: 443,
              fingerprint:
                  TrustedHostsService.fingerprintFromInappCertificate(_cert())),
          isTrue);
    });
  });
}
