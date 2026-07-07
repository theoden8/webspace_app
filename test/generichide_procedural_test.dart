// Regression coverage for $generichide vs backfilled generic
// procedural rules.
//
// Incident: a filter list carrying generic procedural rules
// (`##sel:has-text(...):remove()`) was installed alongside EasyList,
// whose `@@||github.com^$generichide` exception should disable all
// generic cosmetics on github.com. adblock-rust drops generic
// procedurals at parse time, so the app resurrects them by anchoring
// to a synthetic host (procedural_action_backfill.dart) and unioning
// the synthetic-host query into every page — which bypassed the
// generichide exception. The `:remove()` chains then deleted DOM
// nodes out from under GitHub's React, corrupting hydration
// (duplicated skeleton tables, page laid out wider than the screen).
//
// The gate: mergeProceduralActions drops the backfilled set when the
// page is generichide-allowlisted; hostname-scoped procedurals from
// the real-URL query always apply.

@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/procedural_action_backfill.dart';

bool _libraryExists() {
  final cwd = Directory.current.path;
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return File(
          '$cwd/rust/webspace_adblock/target/release/libwebspace_adblock.$ext')
      .existsSync();
}

void main() {
  group('mergeProceduralActions (pure gate)', () {
    const page = ['{"selector":"div.scoped","action":"remove"}'];
    const backfilled = ['{"selector":"div.generic","action":"remove"}'];

    test('without generichide, backfilled generics union in after page rules',
        () {
      final merged = mergeProceduralActions(
        pageActions: page,
        backfilledActions: backfilled,
        genericHide: false,
      );
      expect(merged, [...page, ...backfilled]);
    });

    test('generichide drops the backfilled generics, keeps scoped page rules',
        () {
      final merged = mergeProceduralActions(
        pageActions: page,
        backfilledActions: backfilled,
        genericHide: true,
      );
      expect(merged, page);
    });

    test('generichide with no scoped rules yields nothing to inject', () {
      final merged = mergeProceduralActions(
        pageActions: const [],
        backfilledActions: backfilled,
        genericHide: true,
      );
      expect(merged, isEmpty);
    });
  });

  group('end-to-end: backfill pipeline honors \$generichide', () {
    final libExists = _libraryExists();

    // Mirrors the incident: one generic DOM-removing procedural, the
    // EasyList github generichide exception, and one github-scoped
    // procedural that must survive the gate.
    const rules = '''
##div.promo-box:has-text(Sponsored):remove()
@@||github.com^\$generichide
github.com##div.scoped-flash:remove()
''';

    test('generic :remove() is suppressed on the generichide page', () {
      final rewritten = rewriteGenericProceduralsForBackfill(rules);
      // Sanity: the rewrite anchored the generic rule to the
      // synthetic host so adblock-rust accepts it.
      expect(rewritten, contains('$kBackfillSyntheticHost##div.promo-box'));

      final engine = AdblockEngine.load(rewritten);
      expect(engine, isNotNull);

      final github =
          engine!.cosmeticResources('https://github.com/owner/repo');
      expect(github, isNotNull);
      expect(github!['generichide'], isTrue,
          reason: '@@||github.com^\$generichide must set the flag');

      final pageActions =
          (github['procedural_actions'] as List? ?? const []).cast<String>();
      expect(pageActions.join(), contains('scoped-flash'),
          reason: 'hostname-scoped procedural applies despite generichide');

      final synth = engine
          .cosmeticResources('https://$kBackfillSyntheticHost/');
      final backfilled =
          (synth?['procedural_actions'] as List? ?? const []).cast<String>();
      expect(backfilled.join(), contains('promo-box'),
          reason: 'backfill query must surface the resurrected generic');

      final merged = mergeProceduralActions(
        pageActions: pageActions,
        backfilledActions: backfilled,
        genericHide: github['generichide'] == true,
      );
      expect(merged.join(), contains('scoped-flash'));
      expect(merged.join(), isNot(contains('promo-box')),
          reason: 'generic :remove() must not run on a generichide page');

      engine.dispose();
    }, skip: libExists ? false : 'library not built');

    test('generic :remove() still applies on non-allowlisted pages', () {
      final rewritten = rewriteGenericProceduralsForBackfill(rules);
      final engine = AdblockEngine.load(rewritten);
      expect(engine, isNotNull);

      final other = engine!.cosmeticResources('https://example.com/page');
      expect(other?['generichide'] ?? false, isFalse);

      final pageActions =
          (other?['procedural_actions'] as List? ?? const []).cast<String>();
      final synth = engine
          .cosmeticResources('https://$kBackfillSyntheticHost/');
      final backfilled =
          (synth?['procedural_actions'] as List? ?? const []).cast<String>();

      final merged = mergeProceduralActions(
        pageActions: pageActions,
        backfilledActions: backfilled,
        genericHide: (other?['generichide'] ?? false) == true,
      );
      expect(merged.join(), contains('promo-box'),
          reason: 'the backfill must keep working where no exception applies');

      engine.dispose();
    }, skip: libExists ? false : 'library not built');
  });
}
