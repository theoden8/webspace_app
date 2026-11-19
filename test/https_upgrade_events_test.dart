import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/https_upgrade_engine.dart';
import 'package:webspace/services/onion_location.dart';

/// The upgrade as a state machine, driven event by event.
///
/// The four platform events that can resolve an upgrade arrive in orders the
/// app does not control, from callbacks that know nothing about each other:
/// a navigation, a load start, a finish, a failure, a certificate rejection,
/// and a deadline that fires whenever it fires. Every hazard in this feature
/// is an ordering — two of them shipped on this branch and were only caught by
/// reading the code.
///
/// Before this, the orderings lived in `webview.dart` closures and the only
/// cover was a regex asserting which line came first. That catches a deletion
/// and nothing else: reformat the file and it breaks, write equivalent-but-
/// wrong code and it passes. With the decisions in the engine, an ordering is
/// six lines of Dart, so the interesting ones can simply be enumerated.
///
/// `_Site` below is a fake that models the interface the way CLAUDE.md asks:
/// it plays the call site, obeying outcomes exactly as `webview.dart` does,
/// with no judgement of its own. What it records is what a user would see.
class _Site {
  _Site(this.engine, {this.enabled = true, this.onion});

  final HttpsUpgradeEngine engine;
  final bool enabled;

  /// The site's accepted onion endpoint while it is on Tor, as the posture
  /// hands it to the real call site.
  final OnionEndpoint? onion;

  /// What the webview was told to load, in order. The first entry is the URL
  /// the user asked for only if nothing upgraded it.
  final List<String> loaded = <String>[];

  /// Deadlines armed but not yet fired: upgraded URL -> generation at arming.
  final Map<String, int> _armed = <String, int>{};

  /// Stands in for `PagePhases.asked`, which the real call site bumps at the
  /// top of every `shouldOverrideUrlLoading`.
  int generation = 0;

  bool navigate(String url) {
    generation++;
    final out = engine.onNavigation(url, enabled: enabled, onion: onion);
    if (out.armDeadlineFor != null) _armed[out.armDeadlineFor!] = generation;
    if (out.load != null) loaded.add(out.load!);
    if (!out.cancel) loaded.add(url);
    return out.cancel;
  }

  void loadStarted(String url) => engine.onLoadStarted(url);
  void loadFinished(String url) => engine.onLoadFinished(url);

  void loadFailed(String url, {bool isMainFrame = true}) {
    final out = engine.onLoadFailed(url, isMainFrame: isMainFrame);
    if (out.load != null) loaded.add(out.load!);
  }

  void certificateRejected(String host) {
    final out = engine.onCertificateRejected(host);
    if (out.load != null) loaded.add(out.load!);
  }

  /// Fires a deadline that was armed earlier. The real timer fires whenever it
  /// fires, which is the point: every test below chooses when.
  void deadlineFires(String upgradedUrl) {
    final armedAt = _armed.remove(upgradedUrl);
    if (armedAt == null) return;
    final out = engine.onDeadline(
      upgradedUrl,
      generationAtArm: armedAt,
      currentGeneration: () => generation,
    );
    if (out.load != null) loaded.add(out.load!);
  }

  bool get hasArmedDeadline => _armed.isNotEmpty;
}

void main() {
  late HttpsUpgradeEngine engine;
  late _Site site;

  setUp(() {
    engine = HttpsUpgradeEngine();
    site = _Site(engine);
  });

  group('the happy path', () {
    test('an http navigation is cancelled and reissued over https', () {
      expect(site.navigate('http://example.com/a'), isTrue);
      expect(site.loaded, ['https://example.com/a']);

      site.loadStarted('https://example.com/a');
      site.loadFinished('https://example.com/a');

      // The deadline still fires; by then there is nothing to do.
      site.deadlineFires('https://example.com/a');
      expect(site.loaded, ['https://example.com/a']);
      expect(engine.isKnownHttpOnly('example.com'), isFalse);
    });

    test('a site the engine leaves alone is loaded exactly as asked', () {
      expect(site.navigate('https://example.com/a'), isFalse);
      expect(site.loaded, ['https://example.com/a']);
      expect(site.hasArmedDeadline, isFalse);
    });
  });

  group('failures, in each order the platform can deliver them (HTTPS-008)', () {
    test('error first, then the deadline', () {
      site.navigate('http://dead.example/a');
      site.loadFailed('https://dead.example/a');
      site.deadlineFires('https://dead.example/a');
      expect(site.loaded, ['https://dead.example/a', 'http://dead.example/a'],
          reason: 'the late deadline must not load the fallback twice');
    });

    test('deadline first, then the error for the abandoned attempt', () {
      site.navigate('http://dead.example/a');
      site.deadlineFires('https://dead.example/a');
      site.loadFailed('https://dead.example/a');
      expect(site.loaded, ['https://dead.example/a', 'http://dead.example/a']);
    });

    test('the fallback load is not itself upgraded', () {
      site.navigate('http://dead.example/a');
      site.loadFailed('https://dead.example/a');
      // The webview reissues the http URL, which re-enters shouldOverride.
      expect(site.navigate('http://dead.example/a'), isFalse,
          reason: 'the host is http-only now; upgrading again would loop');
      expect(site.loaded.last, 'http://dead.example/a');
    });

    test('a sub-frame failure is not ours to reverse', () {
      site.navigate('http://example.com/a');
      site.loadFailed('https://cdn.other.example/x.js', isMainFrame: false);
      expect(site.loaded, ['https://example.com/a']);
      expect(engine.isKnownHttpOnly('other.example'), isFalse);
    });
  });

  group('the deadline against a live connection', () {
    test('a response before the deadline shields it', () {
      site.navigate('http://slow.example/a');
      site.loadStarted('https://slow.example/a');
      site.deadlineFires('https://slow.example/a');
      expect(site.loaded, ['https://slow.example/a'],
          reason: 'slow is not dead; abandoning downgrades a working host');
      expect(engine.isKnownHttpOnly('slow.example'), isFalse);
    });

    test('a response AFTER the deadline cannot un-fall-back', () {
      // The ordering the timer makes possible: nothing answered in time, we
      // fell back, and only then does the abandoned attempt say hello.
      site.navigate('http://slow.example/a');
      site.deadlineFires('https://slow.example/a');
      site.loadStarted('https://slow.example/a');
      expect(site.loaded, ['https://slow.example/a', 'http://slow.example/a']);
      expect(engine.isKnownHttpOnly('slow.example'), isTrue);
    });

    test('a failure after a response still falls back', () {
      site.navigate('http://flaky.example/a');
      site.loadStarted('https://flaky.example/a');
      site.loadFailed('https://flaky.example/a');
      expect(site.loaded.last, 'http://flaky.example/a',
          reason: 'answering then dying is a failure, not slowness');
    });
  });

  group('the deadline against a navigation that moved on', () {
    test('a deadline armed for a page the user has left does nothing', () {
      site.navigate('http://slow.example/a');
      site.navigate('https://elsewhere.example/');
      site.deadlineFires('https://slow.example/a');
      expect(site.loaded, ['https://slow.example/a', 'https://elsewhere.example/'],
          reason: 'firing here would yank the user back to a page they left');
    });

    test('but the one armed for the CURRENT navigation still fires', () {
      site.navigate('https://elsewhere.example/');
      site.navigate('http://dead.example/a');
      site.deadlineFires('https://dead.example/a');
      expect(site.loaded.last, 'http://dead.example/a');
    });
  });

  group('certificates', () {
    test('a rejected certificate falls back and never prompts', () {
      site.navigate('http://selfsigned.example/a');
      site.certificateRejected('selfsigned.example');
      expect(site.loaded, [
        'https://selfsigned.example/a',
        'http://selfsigned.example/a',
      ]);
      expect(engine.isKnownHttpOnly('selfsigned.example'), isTrue);
    });

    test('a rejection for a host we did not upgrade is left to the prompt', () {
      site.navigate('https://user-chose.example/a');
      site.certificateRejected('user-chose.example');
      expect(site.loaded, ['https://user-chose.example/a'],
          reason: 'the engine must not invent a downgrade for a navigation '
              'the user made themselves');
      expect(engine.isKnownHttpOnly('user-chose.example'), isFalse);
    });

    test('two upgrades to one host resolve to the one being waited on', () {
      // Root and nested webviews share one engine, and the certificate
      // callback knows only a host.
      site.navigate('http://cert.example/first');
      site.navigate('http://cert.example/second');
      site.certificateRejected('cert.example');
      expect(site.loaded.last, 'http://cert.example/second');

      // And no sibling is left for a later callback to load over the top.
      site.loadFailed('https://cert.example/first');
      expect(site.loaded.last, 'http://cert.example/second');
    });

    test('a deadline after a certificate rejection is a no-op', () {
      site.navigate('http://selfsigned.example/a');
      site.certificateRejected('selfsigned.example');
      site.deadlineFires('https://selfsigned.example/a');
      expect(site.loaded, [
        'https://selfsigned.example/a',
        'http://selfsigned.example/a',
      ]);
    });
  });

  group('the setting', () {
    test('a disabled site is never upgraded and arms nothing', () {
      final off = _Site(HttpsUpgradeEngine(), enabled: false);
      expect(off.navigate('http://example.com/a'), isFalse);
      expect(off.loaded, ['http://example.com/a']);
      expect(off.hasArmedDeadline, isFalse);
    });
  });

  group('the onion endpoint', () {
    const proton =
        'protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd.onion';
    late _Site tor;

    setUp(() {
      tor = _Site(engine,
          onion: OnionEndpoint.of(
              from: 'https://proton.me', to: 'https://$proton/'));
    });

    test('the announcing origin moves to the onion, with the longer deadline',
        () {
      expect(tor.navigate('https://proton.me/mail'), isTrue);
      expect(tor.loaded, ['https://$proton/mail']);
      expect(engine.deadlineFor('https://$proton/mail'), engine.onionDeadline);
      tor.loadStarted('https://$proton/mail');
      tor.loadFinished('https://$proton/mail');
      tor.deadlineFires('https://$proton/mail');
      expect(tor.loaded, ['https://$proton/mail']);
    });

    test('a plain-http clearnet URL goes to the onion, not through https', () {
      final http = _Site(engine,
          onion: OnionEndpoint.of(
              from: 'https://proton.me', to: 'https://$proton/'));
      expect(http.navigate('http://proton.me/'), isTrue);
      expect(http.loaded, ['https://proton.me/']);
      expect(http.navigate('https://proton.me/'), isTrue);
      expect(http.loaded.last, 'https://$proton/');
    });

    test('a failed onion falls back to the clearnet URL for the rest of the run',
        () {
      tor.navigate('https://proton.me/mail');
      tor.loadFailed('https://$proton/mail');
      expect(tor.loaded.last, 'https://proton.me/mail');
      expect(tor.navigate('https://proton.me/inbox'), isFalse);
      expect(tor.loaded.last, 'https://proton.me/inbox');
      expect(engine.isKnownHttpOnly('proton.me'), isFalse,
          reason: 'the onion failed, not the clearnet host');
    });

    test('a lapsed certificate on the onion falls back without a prompt', () {
      tor.navigate('https://proton.me/');
      final out = engine.onCertificateRejected(proton);
      expect(out.cancel, isTrue);
      expect(out.load, 'https://proton.me/');
      expect(tor.navigate('https://proton.me/'), isFalse);
    });

    test('a silent onion falls back at its deadline, a slow one does not', () {
      tor.navigate('https://proton.me/a');
      tor.deadlineFires('https://$proton/a');
      expect(tor.loaded.last, 'https://proton.me/a');

      final slow = _Site(HttpsUpgradeEngine(),
          onion: OnionEndpoint.of(
              from: 'https://proton.me', to: 'https://$proton/'));
      slow.navigate('https://proton.me/b');
      slow.loadStarted('https://$proton/b');
      slow.deadlineFires('https://$proton/b');
      expect(slow.loaded, ['https://$proton/b']);
    });

    test('an onion URL is never upgraded to https', () {
      const torProject =
          '2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion';
      expect(site.navigate('http://$torProject/'), isFalse);
      expect(site.loaded, ['http://$torProject/']);
    });
  });
}
