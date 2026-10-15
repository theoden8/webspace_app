# BUG-033 — An unload disposes the site an activation is opening

Status: open

**Spec:** [webview-pause-lifecycle](../../openspec/specs/webview-pause-lifecycle/spec.md)
and [webspaces](../../openspec/specs/webspaces/spec.md) WEBSPACE-013,
PAUSE-006 ("An eviction under way backs off from a site that starts
activating"), PAUSE-007 ("A superseded switch does not dispose the site a tap
back opens", "A site an unload spares keeps its tier"), [per-site-containers](../../openspec/specs/per-site-containers/spec.md)
CONT-003 ("Memory pressure during a double tap does not strand state")
**Model:** [formal/activation.tla](../../formal/activation.tla)
(`Inv_NoShownEvicted`, `Inv_LoadedNotSaved`: the `markerbytarget` mistake
is the code after attempt 1, `noretry` after attempt 2, `staleplan` and
`tierearly` after attempt 3, and TLC breaks each)
**Tests:** [test/site_unload_engine_test.dart](../../test/site_unload_engine_test.dart)
("… spares a site that starts activating during its capture", "a
memory-pressure unload on the shared jar spares a site that comes on screen
during the jar capture", "… disposes nothing once its plan is superseded
during the capture"),
[test/activation_schedules_test.dart](../../test/activation_schedules_test.dart)
(every schedule within the bound, and the regressions "an eviction under way
disposes the site a tap opens", "a superseded switch disposes the site a tap
back opens")

## Symptom

The user taps a site while the OS reports memory pressure, or taps back to a
site a moment after tapping away from it, and the site opens reloaded from
its start URL: its webview was disposed between the tap and the screen
showing it, so the back stack, scroll and form state the user returned for
are gone.

## Root mechanism / invariant

An unload is decided once, by a plan: an activation's residency step names
the sites on its base domain, a memory-pressure or loaded-site-cap eviction
picks by retention priority, which spares the site on screen and an
activation's target. Then the unload awaits a nav-state capture and, on the
shared jar, a cookie capture in the jar's turn. An activation that begins in
that window can make the victim its target after the decision was made: a
newer tap supersedes the plan, or the pick spared nothing because the tap had
not come yet. The invariant: **a site is disposed only if the decision to
unload it still holds at the dispose: its plan not superseded, and, when
picked by priority, the site still evictable.**

## Fix attempts

1. **2026-04-30 — PR #195.** `setCurrentIndex` marked its target in flight
   and retention priority ranked it `activating`, which no eviction takes.
   *Why*: a pressure event during an activation disposed the soon-to-be-shown
   webview. *Why partial*: the marker was one index, cleared by whichever
   activation ended first, and it guarded the pick only.
2. **2026-10-10 — PR #696.** The marker records the activation version it
   began at, and only that activation clears it. *Why*: on a double tap the
   superseded first activation, whose target is the same, cleared the
   second's marker, so a pressure event during the second could pick the
   target. *Why partial*: still the pick only; an unload already past its
   pick when the tap lands is not asked again.
3. **2026-10-10 — PR #696.** An unload whose reason picks by priority
   (`UnloadReason.pickedByPriority`) asks again just before it disposes, in
   `SiteUnloadEngine.unload` after the nav-state capture and in the shared
   jar's unload after the cookie capture, and backs off if the site is no
   longer evictable. *Why*: found by enumerating every interleaving of two
   pressure events and a tap on a background site on the shared jar: the
   first pressure clears the site's cache, the second picks it for unload,
   the tap lands during the capture, and the dispose takes the site the tap
   is opening. *Why partial*: it asked again only whether a priority pick
   still held, so a superseded plan's unload still disposed; and the capture
   before the check had already moved the spared site's tier.
4. **2026-10-11 — PR #696.** The unload asks its plan's `isStale` at the same
   point, so a superseded switch's conflict unload backs off; and only the
   dispose moves a captured site to `savedForRestore`, so a site the unload
   spares keeps its tier. *Why*: `formal/activation.tla`, split to the code's
   per-site restore calls and its cache-clear await, found both. Site A on
   screen, a tap on B on its base domain starts unloading A, a tap back on A
   lands during the capture and finds A loaded, so it queues no saved state,
   and the first switch's dispose takes A. And attempt 3's back-off left the
   spared site at `savedForRestore`, a tier `pickPromotionTarget` never
   picks, so pressure could not reclaim it until the user opened it again.
   The Dart schedules reproduced both (`[Tap(1), Tap(0)]`, and attempt 3's
   script) once the walk held every unload, not only priority-picked ones, to
   the live target and checked tiers at rest. *Why it closes the path*: every
   unload asks both questions at its last step before the dispose.

5. **2026-10-13 — PR #696.** A webspace switch's unloads were a plan
   outside the model, with a staleness of their own (a select counter) and
   a rule that named every loaded site the new webspace stops showing, the
   site an activation was opening among them: tap a site on the list, then
   a webspace that does not show it while the tap restores its cookies,
   and the switch disposes the site as the tap commits it, leaving the
   screen blank (`Inv_CurrentLoaded` in the schedules, `Inv_NoShownEvicted`
   in the model). The switch is now a flow of the activation table
   (`FlowKind.space`, WEBSPACE-013): its input supersedes an activation in
   flight, as going home does, its plan keeps only evictable sites, and
   each is a choice (`UnloadReason.chosen`, renamed from
   `pickedByPriority`) that its unload asks again about before the dispose.
   *Why*: the dispose's ghost exempted plans outside the model, and the
   switch was one. Either change alone keeps the shown site loaded, since the
   switch runs only from the list, so the model also says what superseding
   alone buys (`Inv_LeftHidden`: no site the switch left opens while it
   stands); the `spaceold` mutant (an input that supersedes nothing) is
   caught by TLC there, and the old code planted in the walk fails
   "a switch unloads the site a tap is opening". *Why partial*: a settings
   save's, a tab's and a home reset's unloads are still outside the model.
6. **2026-10-15 — PR #696.** A home reset's unload (a shortcut launch's,
   or a link's into an always-open-home or incognito site) ran the unload
   table from its capture as a plan outside the model, with a staleness
   that never fired and a victim no pick: a tap of the site while the
   reset captured it committed the site, and the reset then disposed it,
   leaving the screen blank. Modelled as an input of the activation table
   (`UnloadSite`, gated by `Resettable`), TLC broke `Inv_NoShownEvicted` in
   its first world. The input picks its site (`UnloadReason.homeReset` is a
   choice), so the unload asks again before the dispose and backs off.
   *Why*: a reset names a site off screen, as a pressure pick does, and
   the BUG-033 re-ask already covers a pick. The schedules' "a home reset
   backs off from a site a tap opens" fails with the pick planted away, and
   the `recapture` mutant, uncaught in every world since a move stopped
   bumping the version (BUG-029), is caught in the reset world. *Why
   partial*: a settings save's and a tab's unloads are still outside the
   model.

## Known open gaps

A site the user taps after its dispose and before the unload's bookkeeping
returns is rebuilt from saved state, which is the designed path. An unload
outside a plan (a nested open's proxy mismatch) has no staleness to ask, so
it passes one that never fires. The plans still outside the model (a
settings save's, a tab's) are not held to the dispose's ghost.
