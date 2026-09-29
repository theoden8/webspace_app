## ADDED Requirements

### Requirement: PWD-007 - Saved proxy passwords

A saved proxy's password SHALL live in the same secure-storage entry as every
other proxy password, under the reserved key `__saved_proxy__:<id>`, and
SHALL NOT be written to SharedPreferences or to any export (PWD-005). The
list of saved proxies in SharedPreferences (`savedProxies`) SHALL carry only
id, name, type, address and username.

The password SHALL be hydrated at startup before any site resolves a proxy.
Deleting a saved proxy SHALL delete its password; startup SHALL delete any
saved-proxy password whose proxy no longer exists. The per-site orphan
cleanup (PWD-004) SHALL leave saved-proxy keys alone, since they belong to no
site.

A password SHALL NOT be read from the saved-proxy list, even when a backup
was edited to carry one: it could only have been written there to point this
device's traffic at someone else's proxy. An import SHALL therefore leave
every saved proxy without a password, and the post-import hint SHALL ask for
passwords when a saved proxy names a username.

#### Scenario: The export carries no saved proxy password

- **GIVEN** a saved proxy with username `alice` and password `s3cret`
- **WHEN** the user exports settings
- **THEN** the backup's `savedProxies` value names `alice`
- **AND** `s3cret` appears nowhere in the file

#### Scenario: A deleted proxy leaves no password behind

- **GIVEN** a saved proxy with a password
- **WHEN** the user deletes it
- **THEN** secure storage holds no `__saved_proxy__:` entry for it
