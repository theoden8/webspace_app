## ADDED Requirements

### Requirement: PWD-007 - Proxy library passwords

A proxy library password SHALL live in the same secure-storage entry as every
other proxy password: saved credentials under `__saved_credentials__:<id>`, a
saved proxy's typed password under `__saved_proxy__:<id>`. Neither SHALL be
written to SharedPreferences or to any export (PWD-005). The library in
SharedPreferences (`proxyLibrary`) SHALL carry names, types, addresses,
usernames and references only. A site's typed password on a saved gateway is
its own proxy password (PWD-001).

The passwords SHALL be hydrated at startup before any site resolves a proxy.
Deleting an entry SHALL delete its password; startup SHALL delete any library
password whose entry no longer exists. The per-site orphan cleanup (PWD-004)
SHALL leave library keys alone, since they belong to no site.

A password SHALL NOT be read from the library, even when a backup was edited
to carry one: it could only have been written there to point this device's
traffic at someone else's proxy. An import SHALL therefore leave every entry
without a password, and the post-import hint SHALL ask for passwords when the
library names a username.

#### Scenario: The export carries no library password

- **GIVEN** saved credentials with username `alice` and password `s3cret`
- **WHEN** the user exports settings
- **THEN** the backup's `proxyLibrary` value names `alice`
- **AND** `s3cret` appears nowhere in the file

#### Scenario: A deleted entry leaves no password behind

- **GIVEN** saved credentials with a password
- **WHEN** the user deletes them
- **THEN** secure storage holds no `__saved_credentials__:` entry for them
