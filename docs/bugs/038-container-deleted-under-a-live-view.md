# BUG-038 — A site's container outlives the site, or is deleted under a live view

Status: open

**Spec:** [per-site-containers](../../openspec/specs/per-site-containers/spec.md)
CONT-002, CONT-010; [archive](../../openspec/specs/archive/spec.md) ARCH-007,
ARCH-014; link-intent-routing LIR-023 (in `openspec/changes/inactive-tabs/`)
**Model:** [formal/activation.tla](../../formal/activation.tla)
(`Inv_Retired` under the archive and the delete configs; the `closenoframe`
and `deletenoframe` mistakes delete before the frame unmounts the views)
**Tests:** [test/activation_schedules_test.dart](../../test/activation_schedules_test.dart)
(the archive and delete worlds and their regressions),
[test/site_deletion_test.dart](../../test/site_deletion_test.dart)

## Symptom

A site the user deleted, or an archive the user closed, leaves its container
on disk: its cookies, localStorage, IndexedDB and cache, which for an
archive-tier site is what ARCH-007 promises is gone. Or the container is
deleted while a webview still binds it and the next frame builds the site
again on a fresh one.

## Root mechanism / invariant

`deleteContainer` removes a data store nothing references. iOS and macOS
no-op while a webview holds the store; Android refuses a profile in use.
Disposing a site's webview does not release the store: the platform view
stays mounted until the next frame unmounts it, and the page builds one
webview per loaded site, so while the site is still on the list a frame or a
tap builds it again. The invariant is an order: the site leaves the list
(and the loaded set, and the screen) in the commit, the frame unmounts its
webview, then its container goes. Every path that takes a site away must
keep it.

## Fix attempts

1. **2026-05-19, #360 (86222924).** Clear Site Data stopped calling
   `deleteContainer` on a live store and wipes it in place with
   `clearContainerData`. *Why:* the delete no-oped on a store a live
   WKWebView retained. *Partial:* it fixed the clear; a site's delete kept
   `deleteContainer` "after `disposeWebView`", on the belief that disposing
   released the store.
2. **2026-10-03, #641 (b16d1e32).** A deleted host's hosted tabs close
   before its container is deleted (LIR-023). *Why:* another site's
   webview showing a hosted tab bound the store. *Partial:* it covered the
   other sites' webviews, not the site's own, which stayed mounted until a
   frame and could be built again by a tap while the delete awaited.
3. **2026-10-14, #696.** An archive's close takes its sites off the list in
   the commit, waits for the frame, then deletes their containers
   (ARCH-014), checked by the archive world. *Why:* the close disposed the
   webviews, then ran ten awaits before the commit, during which a frame
   rebuilt the sites on their containers. *Partial:* the delete had the same
   order and was not in a world.
4. **2026-10-14, #696.** A delete is a step table in the same order
   (`SiteDeletion`, CONT-010): the commit drops the site, closes the tabs it
   hosted and sweeps what the app kept for it, the frame unmounts its
   webview, then its container goes. The delete world of `activation.tla`
   holds `Inv_Retired` against taps, pressure and frames, and catches the
   old order. The commit also lets go of the webview of every site that
   leaves the list, which an import never did.

## Known open gaps

- Android keeps a profile loaded until the process exits once any webview
  or cookie call used it, and refuses to delete it until then; the next
  launch's sweep (`garbageCollectOrphans`, CONT-004) deletes it. The walk's
  container fake refuses only while a view binds the store, as iOS and macOS
  do.
- An import leaves the replaced sites' containers to that sweep too.
- The delete world runs on containers; on the shared jar the delete's
  cookie cleanup takes the jar's turn (ISO-003), which no jar world takes
  beside a delete.
