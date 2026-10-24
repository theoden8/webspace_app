# IPFS protocol support

## Why

`ipfs://` and `ipns://` name content by hash or by a published name, not by a
server. No webview engine resolves them, so a link to one today falls into
the external-scheme prompt (EXT-004). Loading them through an HTTP gateway is
how Brave started, and needs no IPFS node in the app.

The first draft of this change (PR #200, April 2026) rewrote to a *path*
gateway, `https://ipfs.io/ipfs/<cid>`. That puts every CID on one origin, so
any IPFS page can read any other's storage and the navigation rules see every
IPFS site as one domain. This rewrite uses the *subdomain* form,
`https://<cid>.ipfs.<gateway>/`, which gives each CID an origin of its own.

## What changes

| Piece | Where it lives | Joins |
|---|---|---|
| An IPFS site | `initUrl` keeps `ipfs://` / `ipns://` | `ensureUrlScheme`; no DNS probe (IPFS-001) |
| The gateway URL | a pure engine: `ipfs://<cid>/p` to `https://<cidv1>.ipfs.<gateway>/p`, and back | CIDv0 converted to base32 CIDv1; IPNS names inlined (IPFS-002) |
| Which gateway | one `AppPref`, `dweb.link` by default; a local node is a gateway too | the setting's hint names what the gateway learns (IPFS-003) |
| The route | the gateway request is an https request of the site | the site's proxy, blockers and the LEAK-010/016 gate apply unchanged (IPFS-003) |
| What the user sees | the URL bar maps the gateway origin back to `ipfs://` | only for the configured gateway (IPFS-004) |
| Site identity | each `<cid>.ipfs.<gateway>` host is its own site | the gateway's `ipfs.` and `ipns.` labels join the private suffixes (IPFS-005) |
| Links | an `ipfs://` link is rewritten, then routed like any https link | the rewrite is a reissue the coverage gate asks (IPFS-006) |

## Out of scope

- An embedded IPFS node and peer-to-peer resolution.
- ENS (`.eth`) names: they need an Ethereum resolver, which is a third party.
- Path-gateway links already on the web (`https://ipfs.io/ipfs/...`): they are
  ordinary https links and load as such.
- Pinning or publishing.
