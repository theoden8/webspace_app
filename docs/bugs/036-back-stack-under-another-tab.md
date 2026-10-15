# BUG-036 — A back stack lands under another tab

Status: open

**Spec:** [inactive-tabs](../../openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md)
TAB-003 ("A tab closed while its site activates", "Leaving a site during a
tab switch"), [link-intent-routing](../../openspec/changes/route-outbound-via-lir/specs/link-intent-routing/spec.md)
LIR-034
**Tests:** [test/activation_schedules_test.dart](../../test/activation_schedules_test.dart)
(the tab schedules, and the regressions "an activation restores the state of
a tab closed meanwhile", "going home captures under the tab a switch moves
to"), [test/link_tab_reconcile_entry_test.dart](../../test/link_tab_reconcile_entry_test.dart)
("keys the bytes by what the tab was when the capture started")

## Symptom

A site with tabs opens a tab on another tab's page: its back button walks
another tab's history, or a tab the user parked comes back showing the page
of the tab it was switched from.

## Root mechanism / invariant

A site has one webview and many tabs. The back stack a webview holds is the
history of the tab it was built for; a capture writes it to a file keyed by a
tab, and a build restores a file's bytes into the webview it creates. Each of
those names a tab, and each read the tab from `activeTabId` at its own
moment. `activeTabId` moves on its own (a close of a site with no webview, a
tab switch's pointer move before its disk read), so a key read at one moment
and bytes taken at another named different tabs.

The invariant: a site's webview shows its active tab's history, and each
tab's file holds that tab's history. Its owner is `WebViewTabBinding`: the tab
the webview was built for, and the bytes queued for the next build tagged
with the tab they were read for.

## Fix attempts

1. **2026-10-04, #659 (4309a055).** `captureStateBytes` read the tab and its
   key before the capture and dropped the bytes when either changed while the
   webview answered. Why: a container flip (LIR-034) landing mid-capture
   would otherwise store a tab's bytes under its new identity. Why partial:
   it compared against `activeTabId`, which is not the webview's tab. The tab
   switch moved `activeTabId` before awaiting the incoming tab's file, so an
   unload or go-home capture landing in that await read the new tab, saw it
   unchanged at the reply, and stored the outgoing tab's history under it. The
   restore side had no check at all: bytes the activation read for one tab
   were applied to whichever tab was active when the webview was built.
2. **2026-10-12, #696.** The binding owns the fact: a build binds the webview to
   the active tab and takes queued bytes only when they were read for that
   tab; a capture keys its bytes by the webview's tab and drops them when
   that tab closed or changed identity; the tab switch reads the incoming
   file first, then moves list, pointer and webview in one turn; closing the
   last tab lands on a fresh id, so a capture of the closed tab still in
   flight cannot land in the new tab's file. Found by the tab schedules, which
   drive the real `TabsController` beside the activation stack: the shortest
   break was `OpenTab` then a tap on a site sharing the base domain, whose
   conflict unload captured the outgoing tab under the incoming one.

3. **2026-10-13, #696.** The switch, the close and the duplicate are step
   tables (`TabsController.tabInputs`, `tabFlow`) printed into
   `formal/activation.tla`, over the binding's variables (`built`, `hist`,
   `queued`, `file`: which tab each webview, queue and file holds the history
   of). TAB-003 is four invariants TLC holds every interleaving to
   (`Inv_TabShown`, `Inv_TabFiles`, `Inv_TabBound`, `Inv_TabActive`) on
   `activation_tabs.cfg` and its containers twin, with memory pressure, taps
   on a same-domain site and go-home between the tab flows' awaits. Attempt
   1's shapes are the printed mutants `pointerearly` (the pointer moving
   before the nav read) and `captureatreply` (a capture keyed by the webview
   at its reply, after a rebind moved it), the restore side's `takeany` (a
   build taking bytes queued for another tab); all are caught. A capture is
   two awaits, the webview's reply and the file write, with the drop decided
   between them (`NavCapture`), and the flows have a step at each: the
   replay found the one-step model keying the capture at the reply where the
   code keys it as it starts (now the flow's `capTab`, `capHist`, recorded
   by `Call.reads`), and deciding the drop at the write where the code
   decides it at the webview's reply. The tab steps a schedule marks on the
   site on screen are replayed against the model. Why: a model written by hand
   would have been a second owner of the switch; printing it from the table
   the code runs leaves one. *Why partial:* a tab input on a site off screen
   (an activation inside the tab gate) takes the handler's other path, which
   the model does not hold; the LIR-024 reroute (`tIdent`) is a step the model
   never reaches (`Routed = {}`), so the gap below stays open; a subtree close's
   extra removals and `landOnHomeTab`, `reconcileLinkTabs`, `bindOwnerRunTab`
   are not driven.

## Known open gaps

- Under a process-global proxy (Android, Linux) a tab switch that changes the
  slot's identity awaits the identity change between the pointer move and the
  dispose. Captures key by the webview's tab, so no file is crossed, but no
  schedule drives that path: the walk's proxy topology is per site.
- `landOnHomeTab`, `reconcileLinkTabs` and `bindOwnerRunTab` are not driven
  by the walk; the source gate in `test/tab_switch_rebind_test.dart` still
  covers their `activeTabId` writes.
- `formal/activation.tla` holds the tab flows of the site on screen only: a
  tab input on a site off screen activates it inside the tab gate, a nesting
  the activation table does not print yet, so those schedules are checked by
  the world's invariants and listed in `formal/trace/steps_uncovered.tsv`.
- A capture of a tab that closes while its write is in flight can leave that
  tab's file behind. Nothing restores it (no tab has that id again); the
  startup orphan sweep reaps it.
