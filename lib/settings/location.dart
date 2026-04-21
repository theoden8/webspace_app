/// Per-site geolocation mode. [off] leaves the Geolocation API untouched.
/// [spoof] replaces `navigator.geolocation` with a shim that returns
/// user-supplied coordinates.
enum LocationMode { off, spoof }

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
