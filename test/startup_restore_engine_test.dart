import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/shortcut_id.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/web_view_model.dart';

WebViewModel _site(String url) => WebViewModel(initUrl: url);

ShortcutId _tile(String raw) => ShortcutId.parse(raw)!;

void main() {
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

    test('the first match wins if siteIds collide (hand-edited backup)', () {
      final a = WebViewModel(initUrl: 'https://a.com', siteId: SiteId('dup'));
      final b = WebViewModel(initUrl: 'https://b.com', siteId: SiteId('dup'));
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: SiteId('dup'),
        shortcutUrl: 'https://b.com',
        models: [a, b],
        rememberedRemap: const {},
      );
      expect((r as LaunchOpenSite).index, 0);
    });

    test('siteId gone but remembered remap resolves -> LaunchOpenSite', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: SiteId('stale-id'),
        shortcutUrl: 'https://b.com',
        models: [a, b],
        rememberedRemap: {SiteId('stale-id'): b.siteId},
      );
      expect(r, isA<LaunchOpenSite>());
      expect((r as LaunchOpenSite).index, 1);
    });

    test('remembered remap takes priority over a domain match', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      // url points at a.com, but the user previously rebound to b.
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: SiteId('stale-id'),
        shortcutUrl: 'https://a.com',
        models: [a, b],
        rememberedRemap: {SiteId('stale-id'): b.siteId},
      );
      expect((r as LaunchOpenSite).index, 1);
    });

    test('stale remap (target deleted) falls through to domain match', () {
      final a = _site('https://mail.example.com/inbox');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: SiteId('stale-id'),
        shortcutUrl: 'https://www.example.com/',
        models: [a],
        rememberedRemap: {SiteId('stale-id'): SiteId('also-gone')},
      );
      expect(r, isA<LaunchConfirmExisting>());
      expect((r as LaunchConfirmExisting).index, 0);
      expect(r.shortcutSiteId, 'stale-id');
    });

    test('siteId gone, base-domain match -> LaunchConfirmExisting', () {
      final a = _site('https://a.com');
      final b = _site('https://mail.example.com/inbox');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: SiteId('stale-id'),
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
        shortcutSiteId: SiteId('stale-id'),
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
        shortcutSiteId: SiteId('stale-id'),
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
        shortcutSiteId: SiteId('stale-id'),
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
        currentSiteUrls: {SiteId('s1'): 'https://a.com'},
        pinnedSiteIds: {SiteId('s1')},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('keeps an orphan trail: site deleted but shortcut still pinned', () {
      // s1 was pinned and its url recorded; the site is since gone but the
      // launcher tile remains, so we must keep the url to route the next tap.
      final next = ShortcutUrlLedger.reconcile(
        ledger: {SiteId('s1'): 'https://a.com'},
        currentSiteUrls: const {},
        pinnedSiteIds: {SiteId('s1')},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('prunes entries that are neither current nor pinned', () {
      final next = ShortcutUrlLedger.reconcile(
        ledger: {SiteId('gone'): 'https://gone.com', SiteId('s1'): 'https://a.com'},
        currentSiteUrls: {SiteId('s1'): 'https://a.com'},
        pinnedSiteIds: {SiteId('s1')},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('does not record pinned ids that have no current url', () {
      // An id pinned but not in the model list and not already in the ledger
      // can't be recorded (no url to record) — and is pruned as unreachable.
      final next = ShortcutUrlLedger.reconcile(
        ledger: const {},
        currentSiteUrls: const {},
        pinnedSiteIds: {SiteId('s1')},
      );
      expect(next, isEmpty);
    });

    test('current sites are kept even when not pinned', () {
      final next = ShortcutUrlLedger.reconcile(
        ledger: {SiteId('s1'): 'https://a.com'},
        currentSiteUrls: {SiteId('s1'): 'https://a.com'},
        pinnedSiteIds: const {},
      );
      expect(next, {'s1': 'https://a.com'});
    });

    test('an orphan with no pinned tile is pruned (Android getPinnedShortcuts)', () {
      final next = ShortcutUrlLedger.reconcile(
        ledger: {SiteId('gone'): 'https://gone.com'},
        currentSiteUrls: const {},
        pinnedSiteIds: const {},
      );
      expect(next, isEmpty);
    });
  });

  group('ShortcutTombstones.add (iOS HS-011)', () {
    ShortcutTombstone tomb(String id, {required String url}) =>
        (siteId: SiteId(id), label: id, url: url);

    test('appends a new tombstone', () {
      final next = ShortcutTombstones.add(
        tombstones: const [],
        entry: tomb('s1', url: 'https://a.com'),
      );
      expect(next, [tomb('s1', url: 'https://a.com')]);
    });

    test('de-dupes by siteId and moves the entry to the most-recent end', () {
      final next = ShortcutTombstones.add(
        tombstones: [
          tomb('s1', url: 'https://old.com'),
          tomb('s2', url: 'https://b.com')
        ],
        entry: tomb('s1', url: 'https://new.com'),
      );
      expect(next, [
        tomb('s2', url: 'https://b.com'),
        tomb('s1', url: 'https://new.com')
      ]);
    });

    test('caps the list, evicting the oldest', () {
      final start = [
        for (var i = 0; i < 3; i++) tomb('s$i', url: 'https://$i.com')
      ];
      final next = ShortcutTombstones.add(
        tombstones: start,
        entry: tomb('s3', url: 'https://3.com'),
        cap: 3,
      );
      expect(next.map((t) => t.siteId), ['s1', 's2', 's3']);
    });

    test('pruneLive drops tombstones whose id is now live', () {
      final next = ShortcutTombstones.pruneLive(
        [tomb('s1', url: 'https://a.com'), tomb('s2', url: 'https://b.com')],
        liveSiteIds: {SiteId('s1')},
      );
      expect(next, [tomb('s2', url: 'https://b.com')]);
    });
  });

  group('ShortcutPinState.sitesOpened (HS-017)', () {
    test('a tile opens the site its intent names', () {
      final a = WebViewModel(initUrl: 'https://a.com', siteId: SiteId('a'));
      final b = WebViewModel(initUrl: 'https://b.com', siteId: SiteId('b'));
      expect(
        ShortcutPinState.sitesOpened(
          pinned: {_tile('t1'): SiteId('b'), _tile('t2'): SiteId('a')},
          rememberedRemap: const {},
          models: [a, b],
        ),
        {'t1': b, 't2': a},
      );
    });

    test('two tiles may open one site', () {
      final a = WebViewModel(initUrl: 'https://a.com', siteId: SiteId('a'));
      expect(
        ShortcutPinState.sitesOpened(
          pinned: {_tile('t1'): SiteId('a'), _tile('t2'): SiteId('a')},
          rememberedRemap: const {},
          models: [a],
        ),
        {'t1': a, 't2': a},
      );
    });

    test('a remembered rebind resolves a gone site (HS-011)', () {
      final b = WebViewModel(initUrl: 'https://b.com', siteId: SiteId('b'));
      expect(
        ShortcutPinState.sitesOpened(
          pinned: {_tile('site_gone'): SiteId('gone')},
          rememberedRemap: {SiteId('gone'): SiteId('b')},
          models: [b],
        ),
        {'site_gone': b},
      );
    });

    test('the named site wins over a rebind, as a tap resolves it', () {
      final a = WebViewModel(initUrl: 'https://a.com', siteId: SiteId('a'));
      final b = WebViewModel(initUrl: 'https://b.com', siteId: SiteId('b'));
      expect(
        ShortcutPinState.sitesOpened(
          pinned: {_tile('t1'): SiteId('a')},
          rememberedRemap: {SiteId('a'): SiteId('b')},
          models: [a, b],
        ),
        {'t1': a},
      );
    });

    test('a tile whose site is gone opens nothing', () {
      expect(
        ShortcutPinState.sitesOpened(
          pinned: {_tile('t1'): SiteId('gone')},
          rememberedRemap: {SiteId('gone'): SiteId('also-gone')},
          models: [WebViewModel(initUrl: 'https://a.com', siteId: SiteId('a'))],
        ),
        {'t1': null},
      );
    });
  });

  group('ShortcutPinState.tilesReaching', () {
    final a = WebViewModel(initUrl: 'https://a.com', siteId: SiteId('a'));
    final b = WebViewModel(initUrl: 'https://b.com', siteId: SiteId('b'));

    test('finds every tile that opens the site', () {
      expect(
        ShortcutPinState.tilesReaching(
          siteId: SiteId('a'),
          pinned: {
            _tile('t1'): SiteId('a'),
            _tile('t2'): SiteId('b'),
            _tile('t3'): SiteId('a'),
          },
          rememberedRemap: const {},
          models: [a, b],
        ),
        {'t1', 't3'},
      );
    });

    test('finds a tile rebound to the site (delete a rebind target)', () {
      // A tile pinned before shortcut ids, rebound by the remap.
      expect(
        ShortcutPinState.tilesReaching(
          siteId: SiteId('b'),
          pinned: {_tile('site_old'): SiteId('old')},
          rememberedRemap: {SiteId('old'): SiteId('b')},
          models: [a, b],
        ),
        {'site_old'},
      );
    });

    test('returns empty when nothing reaches the site', () {
      expect(
        ShortcutPinState.tilesReaching(
          siteId: SiteId('b'),
          pinned: {_tile('t1'): SiteId('a')},
          rememberedRemap: const {},
          models: [a, b],
        ),
        isEmpty,
      );
    });
  });

  group('ShortcutPinState.sitesOfTiles (HS-016)', () {
    test('leaves out a tile that opens no site', () {
      final a = WebViewModel(initUrl: 'https://a.com', siteId: SiteId('a'));
      expect(
        ShortcutPinState.sitesOfTiles(
          pinned: {_tile('t1'): SiteId('a'), _tile('t2'): SiteId('gone')},
          rememberedRemap: const {},
          models: [a],
        ),
        {'t1': a},
      );
    });

    test('leaves out an archive-tier site (ARCH-006)', () {
      final archived = WebViewModel(initUrl: 'https://a.com', siteId: SiteId('a'))
        ..isArchiveTier = true;
      expect(
        ShortcutPinState.sitesOfTiles(
          pinned: {_tile('t1'): SiteId('a')},
          rememberedRemap: const {},
          models: [archived],
        ),
        isEmpty,
      );
    });
  });

  group('ShortcutPinState.staleTiles (HS-016)', () {
    final png1 = Uint8List.fromList([1, 2, 3]);
    final png2 = Uint8List.fromList([4, 5, 6]);
    final a = SiteId('a');
    final b = SiteId('b');
    final t1 = _tile('t1');

    test('a tile never written this launch is rewritten', () {
      final plan = ShortcutPinState.staleTiles(
        want: {t1: (site: a, label: 'Mail', icon: png1)},
        shown: const {},
      );
      expect(plan.updates, [(tile: t1, site: a, label: 'Mail', icon: png1)]);
      expect(plan.shown, {t1: (site: a, label: 'Mail', icon: png1)});
    });

    test('a matching tile is left alone', () {
      final plan = ShortcutPinState.staleTiles(
        want: {t1: (site: a, label: 'Mail', icon: Uint8List.fromList([1, 2, 3]))},
        shown: {t1: (site: a, label: 'Mail', icon: png1)},
      );
      expect(plan.updates, isEmpty);
    });

    test('a rename rewrites the label and keeps the icon', () {
      final plan = ShortcutPinState.staleTiles(
        want: {t1: (site: a, label: 'Inbox', icon: png1)},
        shown: {t1: (site: a, label: 'Mail', icon: png1)},
      );
      expect(plan.updates, [(tile: t1, site: a, label: 'Inbox', icon: null)]);
      expect(plan.shown[t1], (site: a, label: 'Inbox', icon: png1));
    });

    test('pointing a tile at another site rewrites it (HS-017)', () {
      final plan = ShortcutPinState.staleTiles(
        want: {t1: (site: b, label: 'Mail', icon: null)},
        shown: {t1: (site: a, label: 'Mail', icon: png1)},
      );
      expect(plan.updates, [(tile: t1, site: b, label: 'Mail', icon: null)]);
      expect(plan.shown[t1], (site: b, label: 'Mail', icon: png1));
    });

    test('a new icon is sent', () {
      final plan = ShortcutPinState.staleTiles(
        want: {t1: (site: a, label: 'Mail', icon: png2)},
        shown: {t1: (site: a, label: 'Mail', icon: png1)},
      );
      expect(plan.updates, [(tile: t1, site: a, label: 'Mail', icon: png2)]);
    });

    test('an icon not known yet never replaces the one a tile has', () {
      final plan = ShortcutPinState.staleTiles(
        want: {t1: (site: a, label: 'Mail', icon: null)},
        shown: {t1: (site: a, label: 'Mail', icon: png1)},
      );
      expect(plan.updates, isEmpty);

      final renamed = ShortcutPinState.staleTiles(
        want: {t1: (site: a, label: 'Inbox', icon: null)},
        shown: {t1: (site: a, label: 'Mail', icon: png1)},
      );
      expect(renamed.updates, [(tile: t1, site: a, label: 'Inbox', icon: null)]);
      expect(renamed.shown[t1], (site: a, label: 'Inbox', icon: png1));
    });

    test('a tile not wanted keeps its record', () {
      final t2 = _tile('t2');
      final plan = ShortcutPinState.staleTiles(
        want: {t1: (site: a, label: 'Inbox', icon: null)},
        shown: {
          t1: (site: a, label: 'Mail', icon: null),
          t2: (site: b, label: 'News', icon: png2),
        },
      );
      expect(plan.updates.map((u) => u.tile), [t1]);
      expect(plan.shown[t2], (site: b, label: 'News', icon: png2));
    });
  });

  group('StartupRestoreEngine.shouldEnterFullscreen (FS-008)', () {
    test('shortcut launch with global option on enters fullscreen', () {
      expect(
        StartupRestoreEngine.shouldEnterFullscreen(
          viaShortcut: true,
          fullscreenOnShortcut: true,
          perSiteFullscreenMode: false,
        ),
        isTrue,
      );
    });

    test('shortcut launch with global option off does not force fullscreen', () {
      expect(
        StartupRestoreEngine.shouldEnterFullscreen(
          viaShortcut: true,
          fullscreenOnShortcut: false,
          perSiteFullscreenMode: false,
        ),
        isFalse,
      );
    });

    test('per-site fullscreen still applies when global option is off', () {
      expect(
        StartupRestoreEngine.shouldEnterFullscreen(
          viaShortcut: true,
          fullscreenOnShortcut: false,
          perSiteFullscreenMode: true,
        ),
        isTrue,
      );
    });

    test('normal in-app switch is unaffected by the global option', () {
      // viaShortcut=false models a tab-strip / drawer switch: the global
      // shortcut option must not pull a non-fullscreen site into fullscreen.
      expect(
        StartupRestoreEngine.shouldEnterFullscreen(
          viaShortcut: false,
          fullscreenOnShortcut: true,
          perSiteFullscreenMode: false,
        ),
        isFalse,
      );
    });

    test('normal in-app switch still honors the per-site flag', () {
      expect(
        StartupRestoreEngine.shouldEnterFullscreen(
          viaShortcut: false,
          fullscreenOnShortcut: false,
          perSiteFullscreenMode: true,
        ),
        isTrue,
      );
    });
  });

  group('StartupRestoreEngine.shouldActivateAfterRestore (NAV-012)', () {
    test('a plain launch with nothing opened yet still lands home', () {
      expect(
        StartupRestoreEngine.shouldActivateAfterRestore(
          indexToRestore: null,
          activatedDuringRestore: false,
        ),
        isTrue,
      );
    });

    test('a site opened while the restore awaited is not closed again', () {
      // The reported drop: GitHub tapped on the home grid during the proxy
      // router's attribution pass, then the restore's closing activation of
      // the plain launch's null target sent the user back home.
      expect(
        StartupRestoreEngine.shouldActivateAfterRestore(
          indexToRestore: null,
          activatedDuringRestore: true,
        ),
        isFalse,
      );
    });

    test('a shortcut target is applied when nothing was opened', () {
      expect(
        StartupRestoreEngine.shouldActivateAfterRestore(
          indexToRestore: 3,
          activatedDuringRestore: false,
        ),
        isTrue,
      );
    });

    test('a shortcut target is applied even after a tap during the restore',
        () {
      expect(
        StartupRestoreEngine.shouldActivateAfterRestore(
          indexToRestore: 0,
          activatedDuringRestore: true,
        ),
        isTrue,
      );
    });
  });
}
