import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/web_view_model.dart';

WebViewModel _site(String url) => WebViewModel(initUrl: url);

void main() {
  group('StartupRestoreEngine.resolveLaunchTarget', () {
    test('returns null when no shortcut intent was passed', () {
      final models = [_site('https://example.com'), _site('https://other.com')];
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: null,
          models: models,
        ),
        isNull,
      );
    });

    test('returns the index of the matching siteId', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: b.siteId,
          models: [a, b],
        ),
        1,
      );
    });

    test('returns null when the shortcut siteId no longer exists', () {
      final models = [_site('https://a.com'), _site('https://b.com')];
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: 'deleted-site-id',
          models: models,
        ),
        isNull,
      );
    });

    test('returns null when the model list is empty', () {
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: 'any-id',
          models: const [],
        ),
        isNull,
      );
    });

    test('returns the first match if siteIds collide (defensive)', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      // siteIds are random UUIDs in production; this tests indexWhere
      // semantics in case a hand-edited backup ever produces a collision.
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: a.siteId,
          models: [a, b],
        ),
        0,
      );
    });
  });

  group('StartupRestoreEngine.resolveLaunch', () {
    test('no intent -> LaunchNone', () {
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: null,
        shortcutUrl: null,
        models: [_site('https://a.com')],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchNone>());
    });

    test('direct siteId hit -> LaunchOpenSite at its index', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: b.siteId,
        shortcutUrl: 'https://b.com',
        models: [a, b],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchOpenSite>());
      expect((r as LaunchOpenSite).index, 1);
    });

    test('siteId gone but remembered remap resolves -> LaunchOpenSite', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://b.com',
        models: [a, b],
        rememberedRemap: {'stale-id': b.siteId},
      );
      expect(r, isA<LaunchOpenSite>());
      expect((r as LaunchOpenSite).index, 1);
    });

    test('remembered remap takes priority over a domain match', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      // url points at a.com, but the user previously rebound to b.
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://a.com',
        models: [a, b],
        rememberedRemap: {'stale-id': b.siteId},
      );
      expect((r as LaunchOpenSite).index, 1);
    });

    test('stale remap (target deleted) falls through to domain match', () {
      final a = _site('https://mail.example.com/inbox');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://www.example.com/',
        models: [a],
        rememberedRemap: const {'stale-id': 'also-gone'},
      );
      expect(r, isA<LaunchConfirmExisting>());
      expect((r as LaunchConfirmExisting).index, 0);
      expect(r.shortcutSiteId, 'stale-id');
    });

    test('siteId gone, base-domain match -> LaunchConfirmExisting', () {
      final a = _site('https://a.com');
      final b = _site('https://mail.example.com/inbox');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://calendar.example.com/day',
        models: [a, b],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchConfirmExisting>());
      expect((r as LaunchConfirmExisting).index, 1);
    });

    test('siteId gone, no domain match -> LaunchOfferCreate', () {
      final a = _site('https://a.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://newsite.example/',
        models: [a],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchOfferCreate>());
      expect((r as LaunchOfferCreate).url, 'https://newsite.example/');
      expect(r.shortcutSiteId, 'stale-id');
    });

    test('placeholder handle (siteId gone, no url) with sites -> LaunchOfferReroute',
        () {
      final a = _site('https://a.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: null,
        models: [a],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchOfferReroute>());
      expect((r as LaunchOfferReroute).shortcutSiteId, 'stale-id');
    });

    test('placeholder handle (siteId gone, no url) with no sites -> LaunchNone',
        () {
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: null,
        models: const [],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchNone>());
    });
  });

  group('ShortcutUrlLedger.reconcile', () {
    test('records url for a pinned site that still exists', () {
      final next = ShortcutUrlLedger.reconcile(
        ledger: const {},
        currentSiteUrls: const {'s1': 'https://a.com'},
        pinnedSiteIds: const {'s1'},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('keeps an orphan trail: site deleted but shortcut still pinned', () {
      // s1 was pinned and its url recorded; the site is since gone but the
      // launcher tile remains, so we must keep the url to route the next tap.
      final next = ShortcutUrlLedger.reconcile(
        ledger: const {'s1': 'https://a.com'},
        currentSiteUrls: const {},
        pinnedSiteIds: const {'s1'},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('prunes entries that are neither current nor pinned', () {
      final next = ShortcutUrlLedger.reconcile(
        ledger: const {'gone': 'https://gone.com', 's1': 'https://a.com'},
        currentSiteUrls: const {'s1': 'https://a.com'},
        pinnedSiteIds: const {'s1'},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('does not record pinned ids that have no current url', () {
      // An id pinned but not in the model list and not already in the ledger
      // can't be recorded (no url to record) — and is pruned as unreachable.
      final next = ShortcutUrlLedger.reconcile(
        ledger: const {},
        currentSiteUrls: const {},
        pinnedSiteIds: const {'s1'},
      );
      expect(next, isEmpty);
    });

    test('current sites are kept even when not pinned', () {
      final next = ShortcutUrlLedger.reconcile(
        ledger: const {'s1': 'https://a.com'},
        currentSiteUrls: const {'s1': 'https://a.com'},
        pinnedSiteIds: const {},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('an orphan with no pinned tile is pruned (Android getPinnedSiteIds)', () {
      final next = ShortcutUrlLedger.reconcile(
        ledger: const {'gone': 'https://gone.com'},
        currentSiteUrls: const {},
        pinnedSiteIds: const {},
      );
      expect(next, isEmpty);
    });
  });

  group('ShortcutTombstones.add (iOS HS-011)', () {
    Map<String, String> tomb(String id, String url) =>
        {'siteId': id, 'label': id, 'url': url};

    test('appends a new tombstone', () {
      final next = ShortcutTombstones.add(
        tombstones: const [],
        entry: tomb('s1', 'https://a.com'),
      );
      expect(next, [tomb('s1', 'https://a.com')]);
    });

    test('de-dupes by siteId and moves the entry to the most-recent end', () {
      final next = ShortcutTombstones.add(
        tombstones: [tomb('s1', 'https://old.com'), tomb('s2', 'https://b.com')],
        entry: tomb('s1', 'https://new.com'),
      );
      expect(next, [tomb('s2', 'https://b.com'), tomb('s1', 'https://new.com')]);
    });

    test('caps the list, evicting the oldest', () {
      final start = [for (var i = 0; i < 3; i++) tomb('s$i', 'https://$i.com')];
      final next = ShortcutTombstones.add(
        tombstones: start,
        entry: tomb('s3', 'https://3.com'),
        cap: 3,
      );
      expect(next.map((t) => t['siteId']), ['s1', 's2', 's3']);
    });

    test('ignores an entry with an empty siteId', () {
      final next = ShortcutTombstones.add(
        tombstones: [tomb('s1', 'https://a.com')],
        entry: tomb('', 'https://x.com'),
      );
      expect(next, [tomb('s1', 'https://a.com')]);
    });

    test('pruneLive drops tombstones whose id is now live', () {
      final next = ShortcutTombstones.pruneLive(
        [tomb('s1', 'https://a.com'), tomb('s2', 'https://b.com')],
        {'s1'},
      );
      expect(next, [tomb('s2', 'https://b.com')]);
    });
  });

  group('ShortcutPinState.effectivePinnedSiteIds', () {
    test('returns the pinned set when there is no remap', () {
      expect(
        ShortcutPinState.effectivePinnedSiteIds(
          pinnedSiteIds: {'a', 'b'},
          rememberedRemap: const {},
        ),
        {'a', 'b'},
      );
    });

    test('folds in a pinned tile\'s rebind target', () {
      // Tile "old" (pinned) was rebound to "new"; "new" is now reachable.
      expect(
        ShortcutPinState.effectivePinnedSiteIds(
          pinnedSiteIds: {'old'},
          rememberedRemap: const {'old': 'new'},
        ),
        {'old', 'new'},
      );
    });

    test('ignores remap entries whose source tile is not pinned', () {
      // A stale remap from a tile the user has since removed should not mark
      // its target as pinned.
      expect(
        ShortcutPinState.effectivePinnedSiteIds(
          pinnedSiteIds: {'a'},
          rememberedRemap: const {'removed': 'target'},
        ),
        {'a'},
      );
    });
  });

  group('ShortcutPinState.tilesReaching', () {
    test('finds the directly-pinned tile', () {
      expect(
        ShortcutPinState.tilesReaching(
          siteId: 'a',
          pinnedSiteIds: {'a', 'b'},
          rememberedRemap: const {},
        ),
        {'a'},
      );
    });

    test('finds a tile rebound to the site (delete a rebind target)', () {
      // Tile "old" (pinned) was rebound to "new"; deleting "new" must still
      // surface "old" so the prompt can manage that tile.
      expect(
        ShortcutPinState.tilesReaching(
          siteId: 'new',
          pinnedSiteIds: {'old'},
          rememberedRemap: const {'old': 'new'},
        ),
        {'old'},
      );
    });

    test('finds both a direct tile and rebound tiles', () {
      expect(
        ShortcutPinState.tilesReaching(
          siteId: 's',
          pinnedSiteIds: {'s', 'x', 'y'},
          rememberedRemap: const {'x': 's', 'y': 'other'},
        ),
        {'s', 'x'},
      );
    });

    test('returns empty when nothing reaches the site', () {
      expect(
        ShortcutPinState.tilesReaching(
          siteId: 'z',
          pinnedSiteIds: {'a'},
          rememberedRemap: const {'a': 'b'},
        ),
        isEmpty,
      );
    });
  });
}
