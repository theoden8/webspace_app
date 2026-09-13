// PROXY-019: the credentials a settings save writes back.
//
// The bug this pins: the credential fields used to be gated by a "Proxy
// requires authentication" checkbox whose restored value came from
// `hasCredentials` — an AND over username and password. A proxy configured
// with only one of the two reopened with the box unticked, and the save read
// that as "no auth" and discarded the field that was set.

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_form_engine.dart';
import 'package:webspace/settings/proxy.dart';

UserProxySettings _stored({
  ProxyType type = ProxyType.SOCKS5,
  String? address = 'proxy.example:1080',
  String? username,
  String? password,
  String? torExitCountry,
}) =>
    UserProxySettings(
      type: type,
      address: address,
      username: username,
      password: password,
      torExitCountry: torExitCountry,
    );

void main() {
  group('applyProxyForm — visible fields are the truth', () {
    test('a password with no username survives the save', () {
      final result = applyProxyForm(
        stored: _stored(password: 'hunter2'),
        fields: const ProxyFormFields(
          type: ProxyType.SOCKS5,
          address: 'proxy.example:1080',
          password: 'hunter2',
        ),
      );

      expect(result.password, 'hunter2');
      expect(result.username, isNull);
    });

    test('a username with no password survives the save', () {
      final result = applyProxyForm(
        stored: _stored(username: 'alice'),
        fields: const ProxyFormFields(
          type: ProxyType.SOCKS5,
          address: 'proxy.example:1080',
          username: 'alice',
        ),
      );

      expect(result.username, 'alice');
      expect(result.password, isNull);
    });

    test('both fields round-trip', () {
      final result = applyProxyForm(
        stored: _stored(username: 'alice', password: 'hunter2'),
        fields: const ProxyFormFields(
          type: ProxyType.HTTP,
          address: 'proxy.example:3128',
          username: 'alice',
          password: 'hunter2',
        ),
      );

      expect(result.type, ProxyType.HTTP);
      expect(result.address, 'proxy.example:3128');
      expect(result.hasCredentials, isTrue);
    });

    test('emptying a field is how a credential is removed', () {
      final result = applyProxyForm(
        stored: _stored(username: 'alice', password: 'hunter2'),
        fields: const ProxyFormFields(
          type: ProxyType.SOCKS5,
          address: 'proxy.example:1080',
        ),
      );

      expect(result.username, isNull);
      expect(result.password, isNull);
    });

    test('an address is stored trimmed, never as an empty string', () {
      final result = applyProxyForm(
        stored: _stored(),
        fields: const ProxyFormFields(
          type: ProxyType.HTTPS,
          address: '  proxy.example:8443  ',
        ),
      );
      expect(result.address, 'proxy.example:8443');

      final cleared = applyProxyForm(
        stored: _stored(),
        fields: const ProxyFormFields(type: ProxyType.HTTPS),
      );
      expect(cleared.address, isNull,
          reason: 'an empty text field is "not set", not ""');
    });
  });

  group('applyProxyForm — hidden fields are not (PROXY-010)', () {
    test('TOR keeps the manual config it hides', () {
      // The controllers still hold whatever the form last drew; under TOR
      // that is not what the user means to store.
      final result = applyProxyForm(
        stored: _stored(username: 'alice', password: 'hunter2'),
        fields: const ProxyFormFields(
          type: ProxyType.TOR,
          address: 'stale.example:9999',
          username: 'stale',
          password: 'stale',
        ),
      );

      expect(result.type, ProxyType.TOR);
      expect(result.address, 'proxy.example:1080');
      expect(result.username, 'alice');
      expect(result.password, 'hunter2');
    });

    test('DEFAULT keeps it too, so switching back restores the proxy', () {
      final result = applyProxyForm(
        stored: _stored(username: 'alice', password: 'hunter2'),
        fields: const ProxyFormFields(type: ProxyType.DEFAULT),
      );

      expect(result.type, ProxyType.DEFAULT);
      expect(result.address, 'proxy.example:1080');
      expect(result.username, 'alice');
      expect(result.password, 'hunter2');
    });

    test('the exit-country pin rides along rather than being retyped', () {
      final result = applyProxyForm(
        stored: _stored(type: ProxyType.TOR, torExitCountry: 'de'),
        fields: const ProxyFormFields(type: ProxyType.TOR),
      );

      expect(result.torExitCountry, 'de');
    });
  });
}
