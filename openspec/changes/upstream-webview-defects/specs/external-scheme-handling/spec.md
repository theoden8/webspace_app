# External Scheme Handling

## ADDED Requirements

### Requirement: EXT-009 - Declining An External-Scheme Window Does Not Hand It To The Parent

EXT-001 through EXT-004 route `intent://` and other external schemes through
parsing, resolution and (where unresolvable) a confirmation prompt. EXT-007 adds
a suppression guard so a silent route cannot loop. All of them are reached from
`onCreateWindow` as well as from `shouldOverrideUrlLoading`, because a
`target="_blank"` link can carry an external scheme.

Every one of those paths ends by returning `false`. Under NESTED-011's defect
that return value causes iOS and macOS to load the raw external-scheme request
into the parent webview, which defeats the whole sequence:

- a resolved intent is loaded as its web equivalent by us, then the raw
  `intent://` is loaded on top by the platform,
- a suppressed silent route (EXT-007) navigates anyway, so the loop guard guards
  nothing,
- an unresolvable intent that should have produced a prompt navigates instead.

The external-scheme paths MUST therefore be able to decline a window without the
platform completing the navigation on their behalf. This is the same fix as
NESTED-011, stated here because the failure mode is different: NESTED-004 loses
a block, EXT loses a user confirmation.

#### Scenario: Resolved intent loads once, as its web equivalent

- **GIVEN** a `target="_blank"` link to `intent://...#Intent;...;end` that
  EXT-002 resolves to an `https://` URL
- **WHEN** the handler loads the resolved URL and returns `false`
- **THEN** the webview navigates to the resolved `https://` URL only
- **AND** the raw `intent://` request is not loaded after it

#### Scenario: Suppressed silent route stays suppressed

- **GIVEN** an external scheme already marked by `ExternalUrlSuppressor` under
  EXT-007
- **WHEN** a gesture-less `onCreateWindow` for the same scheme returns `false`
- **THEN** no navigation occurs on any platform
