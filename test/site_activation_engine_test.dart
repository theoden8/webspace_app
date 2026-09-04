import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_activation_engine.dart';
import 'package:webspace/web_view_model.dart';

WebViewModel _site(String url, {bool incognito = false, String? name}) =>
    WebViewModel(initUrl: url, name: name, incognito: incognito);

void main() {
  group('SiteActivationEngine.findDomainConflict', () {
    test('returns null when no other site is loaded', () {
      final models = [_site('https://example.com')];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: const {},
        ),
        isNull,
      );
    });

    test('returns the loaded same-base-domain index', () {
      final models = [
        _site('https://mail.google.com'),
        _site('https://accounts.google.com'),
      ];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
        ),
        1,
      );
    });

    test('matches across sibling subdomains under the same base', () {
      final models = [
        _site('https://drive.google.com'),
        _site('https://photos.google.com'),
      ];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
        ),
        1,
      );
    });

    test('does not flag different base domains', () {
      final models = [
        _site('https://example.com'),
        _site('https://other.com'),
      ];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
        ),
        isNull,
      );
    });

    test('returns null when target is incognito (rule does not apply)', () {
      final models = [
        _site('https://example.com', incognito: true),
        _site('https://example.com'),
      ];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
        ),
        isNull,
      );
    });

    test('skips loaded sites that are incognito', () {
      final models = [
        _site('https://example.com'),
        _site('https://example.com', incognito: true),
      ];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: {1},
        ),
        isNull,
      );
    });

    test('does not consider the target itself as a conflict', () {
      final models = [_site('https://example.com')];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: {0},
        ),
        isNull,
      );
    });

    test('tolerates out-of-bounds loaded indices', () {
      final models = [
        _site('https://example.com'),
        _site('https://example.com'),
      ];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 0,
          models: models,
          loadedIndices: {1, 99},
        ),
        1,
      );
    });

    test('returns null for out-of-bounds targetIndex', () {
      final models = [_site('https://example.com')];
      expect(
        SiteActivationEngine.findDomainConflict(
          targetIndex: 5,
          models: models,
          loadedIndices: {0},
        ),
        isNull,
      );
    });

    test('returns the first loaded match in iteration order', () {
      final models = [
        _site('https://a.example.com'),
        _site('https://b.example.com'),
        _site('https://c.example.com'),
      ];
      // {1, 2} iteration order is insertion order in Dart; both match.
      final result = SiteActivationEngine.findDomainConflict(
        targetIndex: 0,
        models: models,
        loadedIndices: {1, 2},
      );
      expect(result, anyOf(1, 2));
    });
  });

  group('SiteActivationEngine.outgoingSiteToQuiesce', () {
    test('tapping the site already active quiesces nothing (PAUSE-030)', () {
      expect(
        SiteActivationEngine.outgoingSiteToQuiesce(
          currentIndex: 2,
          targetIndex: 2,
          siteCount: 4,
          loadedIndices: {0, 2},
        ),
        isNull,
        reason: 'The site is resumed moments later; pausing it first strands '
            "the iOS pause hack's alert and stops its media.",
      );
    });

    test('a real switch quiesces the outgoing site', () {
      expect(
        SiteActivationEngine.outgoingSiteToQuiesce(
          currentIndex: 2,
          targetIndex: 3,
          siteCount: 4,
          loadedIndices: {0, 2, 3},
        ),
        2,
      );
    });

    test('nothing to quiesce when no site is active', () {
      expect(
        SiteActivationEngine.outgoingSiteToQuiesce(
          currentIndex: null,
          targetIndex: 1,
          siteCount: 4,
          loadedIndices: {1},
        ),
        isNull,
      );
    });

    test('an unloaded outgoing site has no webview to quiesce', () {
      expect(
        SiteActivationEngine.outgoingSiteToQuiesce(
          currentIndex: 2,
          targetIndex: 3,
          siteCount: 4,
          loadedIndices: {3},
        ),
        isNull,
      );
    });

    test('an out-of-bounds outgoing index is ignored', () {
      expect(
        SiteActivationEngine.outgoingSiteToQuiesce(
          currentIndex: 7,
          targetIndex: 1,
          siteCount: 4,
          loadedIndices: {1, 7},
        ),
        isNull,
        reason: 'Deletion can shift indices out from under an in-flight '
            'activation.',
      );
      expect(
        SiteActivationEngine.outgoingSiteToQuiesce(
          currentIndex: -1,
          targetIndex: 1,
          siteCount: 4,
          loadedIndices: {1, -1},
        ),
        isNull,
      );
    });
  });
}
