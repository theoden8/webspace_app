import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';

/// TAB-006: "Open" in the link long-press menu goes where a tap on the link
/// would. It once did a bare `loadUrl` on the site's controller, which Android
/// never passes through `shouldOverrideUrlLoading`, so a cross-domain link
/// loaded inside the site's container.
void main() {
  group('decideUserOpenedLink', () {
    test('a link inside the site loads in place', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      expect(
        m.decideUserOpenedLink('https://gist.github.com/x', isActive: true),
        NavigationDecision.allow,
      );
    });

    test('a link outside the site opens nested', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      expect(
        m.decideUserOpenedLink('https://wpewebkit.org/', isActive: true),
        NavigationDecision.blockOpenNested,
      );
    });

    test('the browser mode sends an unclaimed link to the browser', () {
      final m = WebViewModel(initUrl: 'https://github.com/')
        ..externalLinkMode = ExternalLinkMode.browser;
      expect(
        m.decideUserOpenedLink('https://wpewebkit.org/', isActive: true),
        NavigationDecision.blockOpenExternal,
      );
    });

    test('a site that left the screen opens nothing', () {
      final m = WebViewModel(initUrl: 'https://github.com/');
      expect(
        m.decideUserOpenedLink('https://wpewebkit.org/', isActive: false),
        NavigationDecision.blockSuppressed,
      );
    });

    test('the block mode blocks an unclaimed link, as a tap would', () {
      final m = WebViewModel(initUrl: 'https://github.com/')
        ..externalLinkMode = ExternalLinkMode.block;
      expect(
        m.decideUserOpenedLink('https://wpewebkit.org/', isActive: true),
        NavigationDecision.blockOutbound,
      );
    });

    test('every mode keeps a claimed link nested', () {
      final m = WebViewModel(initUrl: 'https://github.com/')
        ..externalLinkMode = ExternalLinkMode.block
        ..domainClaims = [
          DomainClaim.baseDomain('github.com'),
          DomainClaim.baseDomain('githubusercontent.com'),
        ];
      expect(
        m.decideUserOpenedLink(
          'https://raw.githubusercontent.com/a/b',
          isActive: true,
        ),
        NavigationDecision.blockOpenNested,
      );
    });
  });

  test('the menu opens links only through the tap routing', () {
    final source = File('lib/main.dart').readAsStringSync();
    final lines = source.split('\n');
    String body(String signature) {
      final start = lines.indexWhere((l) => l.contains(signature));
      expect(start, isNot(-1), reason: '$signature not found in lib/main.dart');
      final end = lines.indexWhere((l) => l == '  }', start);
      return lines.sublist(start, end).join('\n');
    }

    final menu = body('Future<void> _showLinkLongPressMenu(');
    expect(
      menu.contains('.loadUrl('),
      isFalse,
      reason:
          'a load from the menu has to go through _openLinkAsTapped, '
          'or a cross-domain link lands in the site\'s own webview',
    );
    expect(menu.contains('_openLinkAsTapped('), isTrue);

    final open = body('Future<void> _openLinkAsTapped(');
    expect(open.contains('decideUserOpenedLink('), isTrue);
    expect(open.contains('_launchNestedForModel('), isTrue);
    expect(open.contains('launchUrlInSystemBrowser('), isTrue);
    // A blocked link says so through the same hook a tap uses.
    expect(
      RegExp(r'case NavigationDecision\.blockOutbound:\s*_routeOutboundLink\(')
          .hasMatch(open),
      isTrue,
    );
  });
}
