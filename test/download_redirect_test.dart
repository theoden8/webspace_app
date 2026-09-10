import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webspace/services/download_engine.dart';

/// A download that redirects used to ride dart:io's automatic follow, which
/// copies every header of the previous request onto the `Location` target:
/// the site's session cookie, referer and UA reached whichever host the site
/// redirected to (DL-007).
void main() {
  http.Response redirect(String to, [int status = 302]) =>
      http.Response('', status, headers: {'location': to});

  test('a cross-origin redirect carries neither cookie nor referer', () async {
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      if (req.url.host == 'app.example') {
        return redirect('https://attacker.example/x.zip');
      }
      return http.Response('zip', 200);
    });
    await DownloadEngine(client: client).fetch(
      url: 'https://app.example/redirect?to=x',
      cookieHeader: 'session=secret',
      referer: 'https://app.example/page',
      userAgent: 'UA/1',
    );
    expect(seen.length, 2);
    expect(seen[0].headers['cookie'], 'session=secret');
    expect(seen[0].headers['referer'], 'https://app.example/page');
    expect(seen[1].url.toString(), 'https://attacker.example/x.zip');
    expect(seen[1].headers.containsKey('cookie'), isFalse);
    expect(seen[1].headers.containsKey('referer'), isFalse);
    expect(seen[1].headers['user-agent'], 'UA/1');
    expect(seen[1].followRedirects, isFalse);
  });

  test('a same-origin redirect keeps the cookie and referer', () async {
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      if (req.url.path == '/old') return redirect('/new', 301);
      return http.Response('zip', 200);
    });
    await DownloadEngine(client: client).fetch(
      url: 'https://app.example/old',
      cookieHeader: 'session=secret',
      referer: 'https://app.example/page',
    );
    expect(seen[1].url.toString(), 'https://app.example/new');
    expect(seen[1].headers['cookie'], 'session=secret');
    expect(seen[1].headers['referer'], 'https://app.example/page');
  });

  test('the jar is asked for each hop when the caller supplies it', () async {
    final asked = <Uri>[];
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      if (req.url.host == 'app.example') {
        return redirect('https://cdn.example/file');
      }
      return http.Response('zip', 200);
    });
    await DownloadEngine(client: client).fetch(
      url: 'https://app.example/dl',
      cookieHeader: 'session=secret',
      cookieHeaderFor: (uri) async {
        asked.add(uri);
        return 'cdn=token';
      },
    );
    expect(asked, [Uri.parse('https://cdn.example/file')]);
    expect(seen[1].headers['cookie'], 'cdn=token');
  });

  test('a redirect from https to http is refused', () async {
    final client = MockClient((req) async {
      if (req.url.scheme == 'https') return redirect('http://app.example/x');
      fail('the http hop must never be requested');
    });
    expect(
      () => DownloadEngine(client: client).fetch(
        url: 'https://app.example/dl',
        cookieHeader: 'session=secret',
      ),
      throwsA(isA<DownloadException>()),
    );
  });

  test('a redirect loop is cut off', () async {
    var n = 0;
    final client = MockClient((req) async {
      n++;
      return redirect('https://app.example/again$n');
    });
    await expectLater(
      DownloadEngine(client: client).fetch(url: 'https://app.example/dl'),
      throwsA(isA<DownloadException>()),
    );
    expect(n, DownloadEngine.maxRedirects + 1);
  });

  test('a redirect without a location is an HTTP error', () async {
    final client = MockClient((req) async => http.Response('', 302));
    expect(
      () => DownloadEngine(client: client).fetch(url: 'https://app.example/dl'),
      throwsA(isA<DownloadException>()),
    );
  });
}
