# Per-Site Containers

## ADDED Requirements

### Requirement: CONT-009 - The Linux Build Floor Is WPE WebKit 2.50, Not 2.40

The Platform Support Matrix records the version each container primitive landed
in, which for Linux is WPE WebKit 2.40 (`webkit_network_session_new`, the
per-container `WebKitNetworkSession` the engine binds to). That number is
correct for the feature and wrong for the app, and the matrix presents it as
the requirement.

The fork's `flutter_inappwebview_linux` calls
`webkit_web_view_get_theme_color` once, unguarded, with no
`WEBKIT_CHECK_VERSION` anywhere in the plugin. That symbol arrived in WPE 2.50.
Below it the plugin does not compile at all, so no part of WebSpace runs,
containers included. `linux/CMakeLists.txt` compounds it by probing
`wpe-webkit-2.0` with fallbacks to 1.1 and 1.0 and never version-checking: a
2.48 system configures cleanly and then fails at compile with an undeclared
identifier rather than a readable message.

The matrix therefore MUST state the floor that governs, and distinguish it from
the primitive's own floor. Concretely, Debian trixie (2.48) and ParrotOS (2.48)
cannot build us, and no supported Ubuntu release ships a `libwpewebkit-*-dev`
package at all, so naming Ubuntu 23.10+ and Debian trixie as supported is wrong
in both directions. CI already reflects the real floor: `build-linux` pins
`debian:sid-slim` for exactly this reason.

Two follow-ons, either of which relaxes the constraint but neither of which
changes what the matrix must say today:

- If the fork guards the call with `WEBKIT_CHECK_VERSION(2,50,0)`, the floor
  returns to what the container primitive needs and CI can move off the sid pin.
- Until then `CMakeLists.txt` SHOULD fail at configure time with the version it
  found and the version it needs, rather than at compile time with a symbol
  name.

#### Scenario: Building on a 2.48 distribution

- **GIVEN** a machine with WPE WebKit 2.48
- **WHEN** a contributor runs `fvm flutter build linux`
- **THEN** the failure names the WebKit version requirement
- **AND** the documented compatibility matrix already told them 2.50, not 2.40

#### Scenario: The matrix separates the two floors

- **GIVEN** a reader deciding whether a Linux target can run per-site containers
- **WHEN** they read the Platform Support Matrix
- **THEN** they can tell that the container primitive needs 2.40 while the
  plugin needs 2.50, and that the higher of the two is what governs
