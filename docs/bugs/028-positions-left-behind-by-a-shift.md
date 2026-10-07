# BUG-028 — A change that moves rows leaves positions naming other sites

Status: closed

**Spec:** [archive](../../openspec/specs/archive/spec.md) ARCH-004,
[lazy-webview-loading](../../openspec/specs/lazy-webview-loading/spec.md)
**Tests:** [test/site_runtime_test.dart](../../test/site_runtime_test.dart)
("closing an archive keeps the loaded and shown sites on their rows"),
[test/js/site_set_commit.test.js](../../test/js/site_set_commit.test.js)
("only the funnel writes the site list")

## Symptom

After closing an archive whose site had been moved in from the app tier, the
site list showed the wrong webviews: a loaded site lost its webview and a site
that was never opened was built, and the page on screen could switch to the
site below the one the user was on. Under the legacy engine the site shown
then ran with another site's cookies in the shared jar.

## Root mechanism / invariant

The page tracks which sites are built (`loaded`) and which is on screen
(`current`) by position in the site list. A change that removes or moves a row
leaves every position after it naming another site unless the change remaps
them. The invariant: **every write to the site list remaps `loaded` and
`current` to the sites they named, and bumps the activation version.**

## Fix attempts

1. **2026-04-21 — PR #229.** `SiteLifecycleEngine.computeDeletionPatch`
   shifted `loaded`, `current` and the webspace positions after a delete.
   *Why*: the delete did the index arithmetic inline. *Why partial*: it
   covered the delete only; every other row-removing path did its own.
2. **2026-07-08 — PR #472.** Every row-shifting path (delete, reorder,
   import, archive close) bumped the activation version, so an activation
   suspended across an await bailed instead of resuming on a shifted list.
   *Why*: an in-flight switch activated the wrong site. *Why partial*: it
   guarded work in flight, not the positions left behind; the archive close
   dropped the archived rows from `loaded` and the list without shifting the
   rows after them.
3. **2026-07-21 — PR #510.** `computeReorderPatch` remapped positions after a
   reorder of the "All" order. *Why partial*: reorder only.
4. **2026-10-07 — PR #680.** `SiteRuntime.apply` is the only writer of the
   site list, reached only through `_commitSites`; every kind that moves rows
   applies the two patches (an archive close one removed row at a time,
   highest first). *Why it closes the class*: a new way to change the list is
   a new `SiteSetChange` kind, which `apply`'s exhaustive switch makes decide
   its positions, and a write anywhere else fails the gate.

## Known open gaps

None for the list. Positions themselves remain the identity the page uses;
moving `loaded` and `current` to site ids would remove the remapping
altogether.
