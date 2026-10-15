# BUG-029 — A change that moves rows leaves positions naming other sites

Status: open

**Spec:** [archive](../../openspec/specs/archive/spec.md) ARCH-004,
[lazy-webview-loading](../../openspec/specs/lazy-webview-loading/spec.md)
**Tests:** [test/site_runtime_test.dart](../../test/site_runtime_test.dart)
("closing an archive keeps the loaded and shown sites on their rows"),
[test/js/site_set_commit.test.js](../../test/js/site_set_commit.test.js)
("only the funnel writes the site list"),
[test/activation_schedules_test.dart](../../test/activation_schedules_test.dart)
(every interleaving of rows moved while activations and unloads are in flight,
within its bound, and the regressions "an unload removes the position it took
before a move", "a superseded switch leaves the screen on a site it unloaded")
**Model:** [formal/activation.tla](../../formal/activation.tla) (`nohome`;
`loaded` and `current` are sites)

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
Since attempt 9 they are sites, which no write to the list can make name
another; the version bump is what remains.

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
5. **2026-10-10 — PR #696.** The legacy jar's unload took its site's position
   before the capture's awaits and removed that position after them; it now
   finds the position again when it removes it. *Why*: the activation walk
   moved a row while memory pressure unloaded a background site, and the
   unload took the site on screen out of the loaded set instead. *Why
   partial*: attempt 4 remaps the positions `SiteRuntime` holds; a position an
   engine holds across an await is outside the funnel.
6. **2026-10-10 — PR #696.** A switch that a row move supersedes after its
   residency step unloaded the site on screen goes home on its way out
   (LAZY-007). *Why*: attempt 2's version bump makes the switch bail, but the
   bump chooses no site, so the screen stayed on a site with no webview, the
   LAZY-003 placeholder. Found by the same walk, shrunk to four actions.
7. **2026-10-10 — PR #696.** The activation hands the legacy jar's restore
   its own version; the restore had read a fresh one when called. *Why*: a
   walk showed the restore filling the jar for the site that moved into the
   tapped position, but that walk let an action land between two microtasks
   of one flow, which Dart's event loop never does. With actions landing only
   between platform replies, as the walk and the schedule enumeration now
   have them, nothing reaches it: no await separates the activation's last
   version check from the call, and `formal/activation.tla` agrees. Kept so
   the activation is the one owner of its version, and an await added
   between the two later does not reopen it. *Why partial*: not a fix of a
   reachable path; the shape is attempt 5's, a version taken late.
8. **2026-10-12 — PR #696.** `SiteRuntime.activating` holds its target site,
   not its row, and `activation.tla`'s marker names a site (`rows[p]`), so
   memory pressure spares the target wherever a move puts it. *Why*: the row
   was left unremapped on the argument that a move supersedes the activation
   that owns it, which held only while nothing read the marker between the
   move and that activation's exit; the identity needs no argument. *Why
   partial*: `loaded` and `current` are still rows the funnel remaps.
9. **2026-10-12 — PR #696.** `SiteRuntime` holds `loaded` and the site on
   screen (`shown`) as sites; `current` and `loadedRows` are read off them,
   so a move leaves them as they are and a removal takes its sites out of
   both. The deletion and reorder patches, and `SiteLifecycleEngine` with
   them, are gone. The legacy jar's unload, restore and pre-delete take sites
   and the loaded set; `SiteUnloadEngine.unload`, the nested open's
   proxy unloads and the Tor exit pin take sites; `activation.tla`'s `loaded`
   and `current` are sites, and `stalepos`, a mutant that removed a stale
   position, can no longer be written. *Why*: attempt 4 made every write
   remap, and attempts 5 to 8 each found a row held where the remap did not
   reach. With nothing to remap, the invariant needs no owner. On the way,
   four more rows held across awaits went to sites: the nested open's
   mismatched sites, the shortcut-launch home reset's loop, a tab close's
   liveness check, and the Tor pin after a settled exit's unloads; and a
   settings export named the shown site by its row among all sites rather
   than among the app-tier ones it exports. *Why partial*: the version bump
   on a move is kept, so a move still supersedes a switch in flight (attempt
   6), a behaviour now kept by choice rather than need; a row the UI hands an
   input (`setCurrentIndex(int)`) is still read once at its start.
10. **2026-10-12 — PR #696.** The activation takes the site
   (`SiteActivationController.activate(WebViewModel?)`), and so do the
   joins that reached it with a row: every host's `activate`, the tab
   operations (`openTab`, `newTab`, `duplicateTab`, `closeTab`, `moveTab`,
   `openLinkInNewTab`), `revealSite`, `resetHomeOnLaunch`, the shortcut
   launch resolutions, notification taps, the nested open's return to its
   source, the Tabs sheet, the tab strip and the drawer. A row from the UI is
   turned into a site where it is tapped, before any await. The rows held
   across an await that this removed: `deleteSite` confirmed one site and
   deleted whatever sat at its row after the dialog; the site settings
   screen's Clear site data cleared the row captured when the screen opened;
   the tab operations read their row after waiting on the tab gate, so a
   duplicate could copy another site's tab; a shortcut confirmed after its
   prompt, a drawer tap after a webspace switch, the context menu's edit and
   reorder, a webspace switch's unload plan after its connectivity check, a
   backup's restored site after the jar clear, and the hosted-tab sweep's
   loop. *Why*: attempt 9 left the joins taking rows, so each caller had to
   remember to read its row late; a site cannot go stale, only absent, and
   the owner checks that once. `test/rows_across_awaits_test.dart` fails on
   an async function in lib/ that reads a site row past an await. *Why
   partial*: the gate reads source, keyed on a row parameter's name or a
   local read from the site list; a row reached another way (a field, a
   record) is outside it.

11. **2026-10-15 — PR #696.** A row move no longer bumps the activation
   version (`SiteRuntime.apply`, the model's `Move`), so a switch it lands in
   finishes on the site it was opening. *Why*: attempt 2's bump made a switch
   suspended across an await bail rather than resume on a shifted list; since
   attempts 8 to 10 every flow and `SiteRuntime` hold sites, not rows, so a
   shifted list cannot make a flow name another site, and the bump only
   cancelled what the user had asked for. Attempt 6's way home stays for a
   delete or an archive close of another site, which bump the version without
   choosing one; `nohome` moved to the shared-jar delete world, where it is
   still caught, and "a row move mid-switch lets the switch finish" in
   `test/site_activation_walk_test.dart` fails on the bump. *Why partial*: it
   removes the cancel, not the open gaps below.

## Known open gaps

A row reached past an await by a way the gate does not read (a field or a
record holding one). Webspace membership is stored as rows (`siteIndices`),
remapped by the funnel and read synchronously. The schedule enumeration and
the activation model move rows mid-flight on the paths they drive
(activation, memory pressure, the legacy jar); tabs, link routing, webspace
switches and archive close are not driven yet.
