## MODIFIED Requirements

### Requirement: LEAK-001 - Proxy precedence ladder

Every per-site outbound call SHALL resolve through a deterministic
precedence ladder: **explicit per-site override → app-global outbound proxy
→ system / direct**. The implementation lives in `resolveEffectiveProxy`
in [`lib/services/outbound_http.dart`](../../lib/services/outbound_http.dart).

The proxy library (PROXY-030) SHALL be resolved on whichever rung uses it: a
site on a saved proxy or gateway takes it as its explicit override, and an
app-wide proxy on one hands it to every DEFAULT site. A reference that does
not resolve (a missing entry, or credentials paired with a gateway they do
not list) SHALL stop the ladder there and fail closed; it SHALL NOT fall to
the next rung.

#### Scenario: Per-site DEFAULT inherits global

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has proxy type `DEFAULT`
**When** a per-site Dart-side outbound call originates from "Acme"
**Then** the call routes through `HTTP 10.0.0.1:8080`

#### Scenario: Per-site explicit override wins

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has proxy `SOCKS5 127.0.0.1:9050`
**When** a per-site Dart-side outbound call originates from "Acme"
**Then** the call attempts SOCKS5 (not the global)
**And** the global is **not** silently substituted

#### Scenario: Webview honors the same precedence

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has proxy type `DEFAULT`
**When** the webview for "Acme" is created or reconfigured
**Then** `ProxyController.setProxyOverride` is invoked with `HTTP 10.0.0.1:8080`

#### Scenario: A saved proxy is the site's explicit override

**Given** a saved proxy "Work VPN", `SOCKS5 10.8.0.1:1080`
**And** site "Acme" names "Work VPN"
**When** a per-site outbound call originates from "Acme"
**Then** the call routes through `SOCKS5 10.8.0.1:1080`

#### Scenario: A reference that does not resolve does not fall to the global

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" uses a saved gateway that no longer exists
**When** a per-site outbound call originates from "Acme"
**Then** the call is blocked
**And** nothing is sent through `HTTP 10.0.0.1:8080` or direct
