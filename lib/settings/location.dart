/// Per-site geolocation mode.
/// - [off]: leaves the Geolocation API untouched (webview platform default).
/// - [spoof]: replaces `navigator.geolocation` with a shim that returns
///   user-supplied static coordinates with ~2 m jitter.
/// - [live]: replaces `navigator.geolocation` with a shim that calls back
///   into Dart on every `getCurrentPosition`/`watchPosition` to fetch a
///   fresh fix from the platform's native location service. Same shim
///   structure as `spoof` (so timezone override / WebRTC policy / sites'
///   detection routes still apply), but the coordinates are real and
///   change as the device moves.
enum LocationMode { off, spoof, live }

/// Granularity of the fix surfaced by [LocationMode.live]. Three tiers
/// trade off precision for permission posture and OS resource use:
///
/// - [gps]: native GPS provider preferred (Android `ACCESS_FINE_LOCATION`
///   with GPS + NETWORK + PASSIVE, iOS `kCLLocationAccuracyBest`). The
///   page sees the real coordinates and accuracy with only sub-meter
///   jitter so `watchPosition` doesn't return byte-identical frames.
///   Best precision, may spin up the GPS chip, needs sky view to lock.
///   Use when the site genuinely needs metre-level positioning
///   (turn-by-turn navigation, hyper-local search, AR overlays).
/// - [approximate]: same OS-level provider as [gps] (fastest fix wins,
///   GPS or NETWORK) so it actually returns a location even on devices
///   where the NETWORK_PROVIDER backend (NLP / GSM-only) is not
///   configured, then the shim snaps lat/lng to a ~110 m grid before
///   the page sees anything. The reported `accuracy` is inflated to at
///   least ~110 m so the page knows the fix is rounded. This is the
///   middle ground: real GPS-quality fix, fuzzed before exposure. Use
///   for weather, "stores nearby", traffic info — anything that doesn't
///   need exact coordinates but does need a fix that arrives.
/// - [gsm]: Android `ACCESS_COARSE_LOCATION` only with `NETWORK_PROVIDER`
///   only (cell-tower / Wi-Fi triangulation, never GPS), iOS
///   `kCLLocationAccuracyKilometer` so CoreLocation does not power up
///   the GPS chip even under full Precise authorization. The returned
///   fix is then snapped to a ~1.1 km grid and the reported `accuracy`
///   is inflated to at least 1100 m. Privacy-paranoid: the app never
///   even asks for fine-location permission. Note that this tier can
///   return nothing on devices without a Network Location Provider
///   backend (de-Googled phones without microG/UnifiedNlp); use
///   [approximate] for a working middle ground.
///
/// Static [LocationMode.spoof] coordinates are user-supplied and not
/// rounded — the user already chose the precision they want to expose.
enum LocationGranularity { gps, approximate, gsm }

/// Per-site WebRTC policy. HTTP(S)/SOCKS5 proxies only tunnel TCP — WebRTC
/// UDP candidates leak the real client IP even with proxy enabled. This
/// policy controls how the app neutralizes that leak.
///
/// [defaultPolicy] — no restriction.
/// [relayOnly] — force `iceTransportPolicy: 'relay'` on every
/// [RTCPeerConnection] and strip non-relay ICE candidates from local SDP.
/// Real IP does not leak but WebRTC breaks unless a TURN server is reachable.
/// [disabled] — neutralize `RTCPeerConnection` entirely.
enum WebRtcPolicy { defaultPolicy, relayOnly, disabled }

/// Common IANA timezone names shown in the per-site settings picker.
/// The list is intentionally curated — `Intl.supportedValuesOf('timeZone')`
/// returns ~430 zones, which is unwieldy in a dropdown.
const List<MapEntry<String?, String>> commonTimezones = [
  MapEntry(null, 'System default'),
  MapEntry('UTC', 'UTC'),
  MapEntry('Europe/London', 'Europe/London (GMT/BST)'),
  MapEntry('Europe/Dublin', 'Europe/Dublin'),
  MapEntry('Europe/Lisbon', 'Europe/Lisbon'),
  MapEntry('Europe/Paris', 'Europe/Paris (CET/CEST)'),
  MapEntry('Europe/Berlin', 'Europe/Berlin'),
  MapEntry('Europe/Madrid', 'Europe/Madrid'),
  MapEntry('Europe/Rome', 'Europe/Rome'),
  MapEntry('Europe/Amsterdam', 'Europe/Amsterdam'),
  MapEntry('Europe/Brussels', 'Europe/Brussels'),
  MapEntry('Europe/Zurich', 'Europe/Zurich'),
  MapEntry('Europe/Vienna', 'Europe/Vienna'),
  MapEntry('Europe/Warsaw', 'Europe/Warsaw'),
  MapEntry('Europe/Prague', 'Europe/Prague'),
  MapEntry('Europe/Athens', 'Europe/Athens'),
  MapEntry('Europe/Helsinki', 'Europe/Helsinki'),
  MapEntry('Europe/Stockholm', 'Europe/Stockholm'),
  MapEntry('Europe/Oslo', 'Europe/Oslo'),
  MapEntry('Europe/Copenhagen', 'Europe/Copenhagen'),
  MapEntry('Europe/Kyiv', 'Europe/Kyiv'),
  MapEntry('Europe/Moscow', 'Europe/Moscow'),
  MapEntry('Europe/Istanbul', 'Europe/Istanbul'),
  MapEntry('Africa/Cairo', 'Africa/Cairo'),
  MapEntry('Africa/Johannesburg', 'Africa/Johannesburg'),
  MapEntry('Africa/Lagos', 'Africa/Lagos'),
  MapEntry('Asia/Dubai', 'Asia/Dubai'),
  MapEntry('Asia/Tehran', 'Asia/Tehran'),
  MapEntry('Asia/Jerusalem', 'Asia/Jerusalem'),
  MapEntry('Asia/Karachi', 'Asia/Karachi'),
  MapEntry('Asia/Kolkata', 'Asia/Kolkata (IST)'),
  MapEntry('Asia/Bangkok', 'Asia/Bangkok'),
  MapEntry('Asia/Singapore', 'Asia/Singapore'),
  MapEntry('Asia/Hong_Kong', 'Asia/Hong Kong'),
  MapEntry('Asia/Shanghai', 'Asia/Shanghai'),
  MapEntry('Asia/Taipei', 'Asia/Taipei'),
  MapEntry('Asia/Seoul', 'Asia/Seoul'),
  MapEntry('Asia/Tokyo', 'Asia/Tokyo (JST)'),
  MapEntry('Australia/Perth', 'Australia/Perth'),
  MapEntry('Australia/Sydney', 'Australia/Sydney'),
  MapEntry('Pacific/Auckland', 'Pacific/Auckland'),
  MapEntry('Pacific/Honolulu', 'Pacific/Honolulu'),
  MapEntry('America/Anchorage', 'America/Anchorage'),
  MapEntry('America/Los_Angeles', 'America/Los Angeles (PT)'),
  MapEntry('America/Denver', 'America/Denver (MT)'),
  MapEntry('America/Phoenix', 'America/Phoenix'),
  MapEntry('America/Chicago', 'America/Chicago (CT)'),
  MapEntry('America/New_York', 'America/New York (ET)'),
  MapEntry('America/Toronto', 'America/Toronto'),
  MapEntry('America/Mexico_City', 'America/Mexico City'),
  MapEntry('America/Sao_Paulo', 'America/Sao Paulo'),
  MapEntry('America/Buenos_Aires', 'America/Buenos Aires'),
];
