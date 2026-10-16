# BUG-035 — A store written for every site names archived and incognito sites in plaintext prefs

Status: open

**Spec:** [archive](../../openspec/specs/archive/spec.md) ARCH-001 (byte-identical
plaintext prefs), ARCH-006 (per-site feature audit);
[dns-blocklist](../../openspec/specs/dns-blocklist/spec.md) (the iOS
interceptor's tiers)
**Security review:** [2026-09-10](../security/2026-09-10-review.md) SEC-008, SEC-021
**Tests:** [test/archive_neutrality_test.dart](../../test/archive_neutrality_test.dart)
("Block verdicts write no plaintext preference", and the favicon and
webspace rows)

## Symptom

A device backup or filesystem image of `SharedPreferences` names sites the user
keeps in an archive, or opened incognito: their URLs, siteIds or the hosts their
pages requested, in plaintext, after the archive is closed.

## Root mechanism / invariant

A store that every site writes to, through a path that carries no tier: the
widget that renders a site's icon, the webspace list, the verdict a blocker
records. Each was written before archives existed or without them in mind, and
each keeps what it was given. The invariant: **a plaintext preference holds
nothing derived from an archive-tier or incognito site**, so its bytes do not
vary with them (ARCH-001).

## Fix attempts

1. **2026-09-10 — 4616ccf.** `FaviconUrlCache` writes skip archive-tier models,
   and closing an archive removes the entries earlier builds wrote (SEC-008).
   *Why*: the favicon widget had no tier input. *Why partial*: it fixed the one
   store the review found; the other stores that every site writes to were not
   audited for the same shape.
2. **2026-09-10 — 4616ccf.** Archived siteIds leave the plaintext `webspaces`
   pref and backups (SEC-021). *Why*: membership was written positionally for
   every site. *Why partial*: same as attempt 1, one store.
3. **2026-10-11 — PR #696.** The DNS service's merged host-decision cache,
   written for every block verdict on every site and persisted under
   `dns_domain_cache`, is deleted, and a launch removes the stored value.
   Nothing read it for a decision since DNS-018 took it off the bridge, and the
   launch's rule push cleared it right after it loaded. *Why*: found while
   auditing the blocker data for startup races. *Why partial*: it removes this
   store and guards verdicts with a neutrality test; no gate yet finds the next
   store a per-site path writes to plaintext prefs.

## Known open gaps

- No structural gate: a new `SharedPreferences` write reached from a per-site
  path (a verdict, a render, a navigation callback) is caught only if a test
  drives that path for an archive-tier site. A gate over source text that lists
  every plaintext pref key with its scope (app-wide setting, machine state, or
  per-site with a tier filter) would lift it.
