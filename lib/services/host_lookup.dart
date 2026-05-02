/// Hot-path helpers shared by [DnsBlockService] and [ContentBlockerService].
/// Both services do per-request URL → host extraction + suffix-walk lookups
/// against a `Set<String>` of blocked domains. Centralising the helpers
/// keeps the two services on the same fast implementation:
///
/// * [extractHost] avoids `Uri.parse` (full RFC 3986 validation, allocates
///   a `Uri` object) and conditionally lowercases — no allocation when the
///   host is already lowercase.
/// * [hostInSet] walks the suffix hierarchy with `String.indexOf` instead
///   of allocating a new substring per level.
library;

/// Extract the lowercase host from `scheme://host[:port]/...` without
/// `Uri.parse`-style RFC validation. Handles userinfo (`user:pass@host`)
/// and IPv6 literals (`[2001:db8::1]`). Returns null when no `://` is
/// present (relative URLs, `data:` / `about:` / `javascript:` etc.).
///
/// Case-folds only when the host actually contains uppercase ASCII —
/// `String.toLowerCase()` always allocates a new string, so for the
/// common case of already-lowercase hosts we return the substring
/// directly.
String? extractHost(String url) {
  final i = url.indexOf('://');
  if (i < 0) return null;
  final start = i + 3;
  int end = url.length;
  for (var j = start; j < url.length; j++) {
    final c = url.codeUnitAt(j);
    // '/', '?', '#' all terminate the authority.
    if (c == 0x2F || c == 0x3F || c == 0x23) {
      end = j;
      break;
    }
  }
  // Strip userinfo. The LAST '@' before '/' delimits userinfo from host
  // (per RFC 3986); intermediate '@'s would be percent-encoded.
  int hostStart = start;
  for (var j = start; j < end; j++) {
    if (url.codeUnitAt(j) == 0x40 /* @ */) hostStart = j + 1;
  }
  // IPv6 literal: host is bracketed, port (if any) follows the ']'.
  if (hostStart < end && url.codeUnitAt(hostStart) == 0x5B /* [ */) {
    for (var j = hostStart; j < end; j++) {
      if (url.codeUnitAt(j) == 0x5D /* ] */) {
        return _slice(url, hostStart, j + 1);
      }
    }
    return null;
  }
  // Strip :port — first ':' between hostStart and end terminates the host.
  int hostEnd = end;
  for (var j = hostStart; j < end; j++) {
    if (url.codeUnitAt(j) == 0x3A /* : */) {
      hostEnd = j;
      break;
    }
  }
  return _slice(url, hostStart, hostEnd);
}

String _slice(String url, int start, int end) {
  bool hasUpper = false;
  for (var j = start; j < end; j++) {
    final c = url.codeUnitAt(j);
    if (c >= 0x41 && c <= 0x5A) {
      hasUpper = true;
      break;
    }
  }
  final s = url.substring(start, end);
  return hasUpper ? s.toLowerCase() : s;
}

/// Substring-based suffix-walk lookup. Same semantics as
/// `set.contains(host)` then walking parents (`a.b.c` → `b.c` → ...) via
/// `host.indexOf('.', from)` — never allocates an intermediate substring
/// for the comparison since `Set<String>.contains` accepts a key built
/// directly from `String.substring(start)`. Stops before the eTLD label
/// (`com` alone is never matched).
bool hostInSet(String host, Set<String> set) {
  if (set.isEmpty) return false;
  if (set.contains(host)) return true;
  int dot = host.indexOf('.');
  while (dot >= 0 && dot < host.length - 1) {
    final parent = host.substring(dot + 1);
    if (!parent.contains('.')) break;
    if (set.contains(parent)) return true;
    dot = host.indexOf('.', dot + 1);
  }
  return false;
}

/// Bounded host->bool cache with FIFO eviction. Designed for the per-URL
/// hot path in [DnsBlockService.isBlocked] / [ContentBlockerService.isBlocked]
/// where the same host repeats dozens of times per page.
///
/// Eviction is O(1) without allocating an iterator: insertion order is
/// tracked in a fixed-size `List<String?>` ring, and the oldest entry is
/// evicted via `_ring[head++ % cap]`. Hits never reorder the ring — read
/// path is a single `Map` lookup. Re-inserting an existing key keeps its
/// original position so a hot host doesn't keep evicting itself.
class HostFifoCache {
  final int capacity;
  final List<String?> _ring;
  int _head = 0;
  int _size = 0;
  final Map<String, bool> _map = <String, bool>{};

  HostFifoCache(this.capacity)
      : _ring = List<String?>.filled(capacity, null);

  bool? operator [](String key) => _map[key];

  void put(String key, bool value) {
    if (_map.containsKey(key)) {
      _map[key] = value;
      return;
    }
    if (_size >= capacity) {
      final evicted = _ring[_head];
      if (evicted != null) _map.remove(evicted);
      _ring[_head] = key;
      _head = (_head + 1) % capacity;
    } else {
      _ring[(_head + _size) % capacity] = key;
      _size++;
    }
    _map[key] = value;
  }

  void clear() {
    _map.clear();
    _head = 0;
    _size = 0;
    for (var i = 0; i < _ring.length; i++) {
      _ring[i] = null;
    }
  }

  int get length => _map.length;
}
