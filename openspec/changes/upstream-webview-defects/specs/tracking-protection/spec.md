# Tracking Protection

## ADDED Requirements

### Requirement: ETP-025 - The Plugin's Console Wrappers Are Masked Like Ours

The anti-fingerprinting shim masks every function it installs so
`Function.prototype.toString` reports `[native code]`, because an overridden
built-in that admits to being a JS wrapper is a stronger signal than the value
it was hiding.

The plugin installs five of its own at document start, in every content world:
`console.log`, `console.debug`, `console.error`, `console.info` and
`console.warn`, replaced by `ConsoleLogJS` so page output can be bridged to the
developer-tools console. These are not ours, so the masking funnel never saw
them, and `console.log.toString()` returns readable JS naming the plugin.

That is a browser-identifying tell that survives Tracking Protection being on,
and it is available to any script without permission or user interaction. The
five console methods MUST be registered into the same masking funnel as every
other injected wrapper.

This is orthogonal to the console shim's other defect (arguments are
string-concatenated, so objects arrive as `[object Object]` and `Error` message
and stack are dropped on iOS, macOS and Linux). That one costs us fidelity in
our own developer tools, not privacy, and is tracked in the upstream audit
rather than here.

#### Scenario: A page probes the console

- **GIVEN** a site with Tracking Protection on
- **WHEN** it evaluates `console.log.toString()`
- **THEN** it receives the `[native code]` form, as it does for every other
  function the shim replaces

#### Scenario: The funnel covers new wrappers

- **GIVEN** the set of functions injected into the page at document start,
  including those the plugin injects rather than the app
- **WHEN** the masking funnel is built
- **THEN** every one of them is registered, and a wrapper that is not is caught
  by the structural gate rather than by a site
