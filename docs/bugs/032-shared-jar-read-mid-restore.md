# BUG-032 — A second switch reads the shared jar while the first has it emptied

Status: closed

**Spec:** [per-site-cookie-isolation](../../openspec/specs/per-site-cookie-isolation/spec.md)
ISO-003 ("Concurrent activation is serialized")
**Model:** [formal/jar_nonempty.tla](../../formal/jar_nonempty.tla) (one restore
at a time; the interleaving of two is outside it)
**Tests:** [test/site_activation_walk_test.dart](../../test/site_activation_walk_test.dart)
("a tap back lands while the first restore refills the jar", and the random
walks on the shared jar)

## Symptom

Under the legacy engine, a site the user signed in to is signed out after a
quick switch away and back: its stored session is gone, not only its live one.

## Root mechanism / invariant

Every activation snapshots the shared jar, saves each loaded site's share of it
to storage, empties the jar and refills it. A second activation whose snapshot
lands after the first's nuke and before its refill finishes reads an empty or
partial jar and saves that as the loaded sites' sessions. The invariant: **no
operation reads the jar while another has it emptied.**

## Fix attempts

1. **2026-07-08 — PR #472.** Removed the version-guard bail between the nuke
   and the refill, so a superseded restore always refills the jar. *Why*: the
   bail left the jar empty, and the next activation persisted `[]` for every
   loaded site. *Why partial*: the superseded restore now kept running after
   its nuke, and nothing stopped a newer activation's snapshot from reading the
   jar during that refill. `jar_nonempty.tla` checks one restore against
   supersession, so the interleaving of two was outside the model.
2. **2026-10-10 — PR #696.** `CookieIsolationEngine` runs its operations on the
   jar one at a time through a `SerialQueue`: a restore, an unload's capture
   and a delete's cleanup each take a turn, and a restore superseded while
   waiting bails before it reads. An unload whose site is no longer loaded
   when its turn comes does nothing: two plans in flight can both name one
   site, and the second capture read a jar refilled without it. *Why*: found
   by the activation walk, the first shrunk to six actions (sign in to A, tap
   B, tap A while B's restore runs), the second to eight; both are named
   regressions. *Why it closes the class*: every read and write of the jar the
   engine makes holds the turn, and a capture runs only for a site the jar
   still holds, so no capture sees a jar emptied of the site it saves.

## Known open gaps

None for the engine's own operations. A page's own cookie write that lands
between a snapshot and its nuke is lost: the shared jar cannot order the page
against the engine, which is what per-site containers remove. The walk's
`Login` settles before it writes for this reason.
