# Backup compatibility corpus

One directory per release, holding what that release wrote for the inputs in
`tool/backup_compat/superset.json`:

- `backup_maximal.json`: every setting away from its default, as exported.
- `backup_minimal.json`: one untouched site, default prefs.
- `qr_maximal.txt` (v0.2.3+): the first site's `webspace://qr/site/v1/` link.
- `links.json` (v0.2.3+): how the release unwrapped each `webspace://` link in
  the superset's corpus (`null` rejected, `!throws` raised).
- `prefs_writes.json`: every SharedPreferences key the release's `lib/` writes
  and the type it writes it as (`tool/backup_compat/prefs_keys.js`), which is
  what an upgrade from that release finds on the device.

The files are produced by the release's own code, not written by hand:
`tool/backup_compat/generate.sh <tag>` checks the tag out, swaps in a shim for
any API it predates, and runs `tool/backup_compat/generator_test.dart` there.
`test/settings_backup_compat_test.dart` imports each one at HEAD (BACKUP-012).

Do not edit a release's files. To cover a new field, add it to
`superset.json`: the next release's fixtures carry it, the older releases'
files stay as they are, and the test checks those import it as the default.
