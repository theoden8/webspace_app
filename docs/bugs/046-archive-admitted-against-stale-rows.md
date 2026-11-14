# BUG-046: An archive's sites are admitted against rows that change before they land

Status: open

**Spec:** [archive](../../openspec/specs/archive/spec.md) ARCH-016, ARCH-017
**Security:** SEC-044 (first instance), [SEC-056](../security/2026-11-07-review.md) (recurrence)
**Tests:** [test/archive_round_trip_test.dart](../../test/archive_round_trip_test.dart)
("ARCH-016, SEC-044: an archived site whose id an app-tier site holds",
"ARCH-017, SEC-044: an archive opened while an import applies")

## Symptom

Two listed sites under one id: a lookup by id (`SitesById.siteOf`) names
whichever comes first, and a close can take the wrong one out of the
collections. Or an open archive whose rows a settings import cleared under it.

## Root mechanism / invariant

No site joins the lists under a listed site's id (R8). An archive open
decides each site's listed id (`Admitted.of`) from the rows listed when it
admits, so the invariant holds only if no other change of the rows lands
between that admission and the open's commit. The open awaits in between (a
container key per site, the commit's own prepare), and so does a settings
import between sealing the archives and replacing the rows.

## Fix attempts

1. **2026-11-08, #947 (`ec6c91d9`).** An archive open admits its sites
   against the listed ids and runs a clashing one under a fresh id;
   `SiteRuntime.apply` asserts every join (ARCH-016). *Why:* an archive
   sealed under an id an app-tier site holds (a backup brought it back)
   joined under that id. *Why partial:* the admission reads the rows several
   awaits before the commit lands, and the settings import, which brings
   sites back under their own ids, sealed the archives in their queue's turn
   but replaced the rows outside it. An archive opened in that gap was
   admitted against the rows before the import (a duplicate id, caught only
   by the debug assert), or had its rows cleared by the replace while it
   stayed open.
2. **This change (SEC-056).** The import applies in the archives' turn
   (`ArchiveController.closeAllThen`), and `SitesReplaced` carries the
   `ArchivesClosed` witness that turn makes, which `apply` asserts is still
   held (ARCH-017). *Why:* the import is the one change that lists sites under
   ids it brings; every other add mints a fresh id, and another archive's open
   shares the queue. *Why partial:* the admission still runs before the
   open's awaits, so a future change that lists sites under their own ids
   outside the archives' turn would reopen it.

## Known open gaps

- Admission at the land, where `activation.tla`'s `Join` chooses the id: the
  open would decide each listed id in the turn its commit lands in, whatever
  else changed the rows. Owned by printing `Join` from the code.
