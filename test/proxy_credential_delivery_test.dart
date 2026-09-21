import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart' show userProxyToInappProxy;
import 'package:webspace/settings/proxy.dart';

/// A proxy credential has to arrive in the form the target platform reads
/// (PROXY-025), and the two platforms that read `ProxyRule` read different
/// ones.
///
/// Linux's WPE binding takes `url` alone, so the credential has to stay in
/// the URL's userinfo. Apple's `ProxyRule.toProxyConfiguration` builds its
/// endpoint from `URL.host` and `URL.port` -- which discards userinfo --
/// and takes the credential from the separate `username`/`password` fields
/// to hand to `ProxyConfiguration.applyCredential`.
///
/// Sending only the URL form authenticates with nothing on Apple: the proxy
/// answers `407`, the page fails, and the settings screen still reports the
/// proxy as configured. That is the "configured and not in force" shape of
/// BUG-014, reached from the app's side rather than the platform's, and it
/// is invisible in a test that only reads the URL back.
void main() {
  UserProxySettings proxy({String? username, String? password}) =>
      UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:9050',
        username: username,
        password: password,
      );

  test('a credentialed proxy carries the credential as fields', () {
    final rule = userProxyToInappProxy(
      proxy(username: 'alice', password: 's3cret'),
    )!
        .proxyRules
        .first;
    expect(rule.username, 'alice');
    expect(rule.password, 's3cret');
  });

  test('and keeps carrying it as userinfo, which is all Linux reads', () {
    final rule = userProxyToInappProxy(
      proxy(username: 'alice', password: 's3cret'),
    )!
        .proxyRules
        .first;
    expect(Uri.parse(rule.url).userInfo, 'alice:s3cret');
  });

  test('a username with reserved characters survives both forms', () {
    final rule = userProxyToInappProxy(
      proxy(username: 'a:b@c', password: 'p/w?d'),
    )!
        .proxyRules
        .first;
    // The fields are handed over verbatim; only the URL form is escaped,
    // and it has to round-trip or Linux authenticates as someone else.
    expect(rule.username, 'a:b@c');
    expect(rule.password, 'p/w?d');
    expect(Uri.parse(rule.url).userInfo, 'a%3Ab%40c:p%2Fw%3Fd');
  });

  test('an uncredentialed proxy leaves the fields absent', () {
    final rule = userProxyToInappProxy(proxy())!.proxyRules.first;
    expect(rule.username, isNull);
    expect(rule.password, isNull);
    expect(Uri.parse(rule.url).userInfo, isEmpty);
  });
}
