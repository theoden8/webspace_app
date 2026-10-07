/// Which host a URL names, and which hosts count as one site. Pure Dart, so
/// engines and stores reach it without the model file.
library;

/// A host name as the services compare it: lowercase, without IPv6
/// brackets or a trailing root dot. Only built through [Host.new], so a
/// value of this type has been normalized; it is still a [String]
/// everywhere one is expected.
extension type const Host._(String name) implements String {
  factory Host(String raw) {
    var h = raw.trim().toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    return Host._(h);
  }

  /// The http(s) host [url] names, or null for any other URL.
  static Host? ofWebUrl(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final host = Host(uri.host);
    return host.isEmpty ? null : host;
  }

  /// This host with one leading `www.` folded, so `example.com` and
  /// `www.example.com` read as the same site.
  Host get withoutWww => startsWith('www.') ? Host._(substring(4)) : this;
}

/// The host of [url], or [url] itself when it has none (a bare domain).
String extractDomain(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? url : host;
}

/// Common multi-part TLDs (country-code second-level domains)
/// These need special handling because the TLD is effectively two parts (e.g., .co.uk)
const Set<String> _multiPartTlds = {
  'co.uk', 'org.uk', 'me.uk', 'ac.uk', 'gov.uk',
  'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  'co.nz', 'net.nz', 'org.nz', 'govt.nz',
  'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp',
  'com.br', 'net.br', 'org.br', 'gov.br',
  'co.in', 'net.in', 'org.in', 'gov.in',
  'com.mx', 'org.mx', 'gob.mx',
  'co.za', 'org.za', 'gov.za',
  'com.sg', 'org.sg', 'gov.sg', 'edu.sg',
  'co.kr', 'or.kr', 'go.kr',
  'com.cn', 'net.cn', 'org.cn', 'gov.cn',
  'com.tw', 'org.tw', 'gov.tw',
  'com.hk', 'org.hk', 'gov.hk',
  'co.id', 'or.id', 'go.id',
  'com.ph', 'org.ph', 'gov.ph',
  'co.th', 'or.th', 'go.th',
  'com.vn', 'gov.vn',
  'com.my', 'org.my', 'gov.my',
  'co.il', 'org.il', 'gov.il',
  'com.tr', 'org.tr', 'gov.tr',
  'com.pl', 'org.pl', 'gov.pl',
  'co.de', 'com.de',
  'com.fr', 'org.fr', 'gouv.fr',
  'co.it', 'org.it', 'gov.it',
  'co.es', 'org.es', 'gob.es',
  'co.nl', 'org.nl',
  'com.ar', 'org.ar', 'gov.ar',
  'com.ru', 'org.ru', 'gov.ru',
};

/// Private suffixes: single registrants who hand out subdomains to mutually
/// untrusting third parties. Without these, `victim.github.io` and
/// `attacker.github.io` share a base domain — same cookie container, and
/// `NavigationDecisionEngine` reads a hop between them as same-site.
const Set<String> _privateSuffixes = {
  'github.io',
  'pages.dev',
  'workers.dev',
  'vercel.app',
  'netlify.app',
  'web.app',
  'firebaseapp.com',
  'appspot.com',
  'azurewebsites.net',
  'herokuapp.com',
  'myshopify.com',
  'blogspot.com',
  'wordpress.com',
};

/// Second-level labels that a two-letter ccTLD registry almost always
/// operates as a public suffix (`co.uk`, `com.au`, `ne.jp`, …). Used only
/// where [_multiPartTlds] has no entry for the pair: guessing that the pair
/// is registrable would put every registrant under it — `a.com.ke` and
/// `b.com.ke` — into one site.
const Set<String> _ambiguousCcTldSecondLevels = {
  'co', 'com', 'net', 'org', 'edu', 'gov', 'govt',
  'gob', 'gouv', 'ac', 'ne', 'or', 'go', 'mil', 'int',
};

bool _isIPv4Address(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    final num = int.tryParse(part);
    if (num == null || num < 0 || num > 255) return false;
  }
  return true;
}

/// Checks if a string is an IPv6 address (with or without brackets).
bool _isIPv6Address(String host) {
  final cleaned = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  // Simple check: contains colons and valid hex characters
  if (!cleaned.contains(':')) return false;
  final validChars = RegExp(r'^[0-9a-fA-F:]+$');
  return validChars.hasMatch(cleaned);
}

/// Extracts the second-level domain (SLD + TLD) from a URL.
/// Used for cookie isolation - all subdomains of the same second-level domain
/// will have their webviews mutually excluded.
/// Handles multi-part TLDs like .co.uk, .com.au, etc.
/// IP addresses are returned as-is (they don't have subdomains).
/// Example: 'mail.google.com' -> 'google.com'
/// Example: 'api.github.com' -> 'github.com'
/// Example: 'www.google.co.uk' -> 'google.co.uk'
/// Example: 'victim.github.io' -> 'victim.github.io'
/// Example: '192.168.1.1' -> '192.168.1.1'
/// Example: '[::1]' -> '[::1]'
///
/// There is no public suffix list here (a vendored PSL would be a committed
/// derivative). The table covers the common ccTLD second levels plus the
/// [_privateSuffixes] that hand subdomains to strangers; anything else that
/// *looks* like a registry suffix resolves to per-host isolation rather than
/// a guess, since guessing low merges unrelated sites.
String getBaseDomain(String url) {
  final host = extractDomain(url);

  // IP addresses should be returned as-is - they're already unique identifiers
  if (_isIPv4Address(host) || _isIPv6Address(host)) {
    return host;
  }

  final parts = host.split('.');

  if (parts.length >= 3) {
    final possibleTld = '${parts[parts.length - 2]}.${parts.last}';
    if (_multiPartTlds.contains(possibleTld) ||
        _privateSuffixes.contains(possibleTld)) {
      return '${parts[parts.length - 3]}.$possibleTld';
    }
    // The pair looks like a registry suffix the table doesn't list. Resolve
    // it the over-isolating way — assume it IS a suffix — so unrelated
    // registrants never collapse into one site. With no label above it
    // (`a.com.ke`) that degrades to host equality.
    if (parts.last.length == 2 &&
        _ambiguousCcTldSecondLevels.contains(parts[parts.length - 2])) {
      return '${parts[parts.length - 3]}.$possibleTld';
    }
  }

  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}.${parts.last}';
  }
  return host;
}

/// Domain aliases for treating different domains as equivalent for navigation.
/// Key is the alias domain, value is the canonical domain.
/// Used ONLY for nested webview URL blocking (not cookie isolation).
/// All Google properties (gmail.com, regional domains, etc.) are treated as google.com.
const Map<String, String> _domainAliases = {
  'gmail.com': 'google.com',
  // YouTube is part of Google's SSO family — `accounts.youtube.com/SetSID`
  // is a mandatory hop when signing into play.google.com, gmail, etc.,
  // since Google syncs session cookies into the YouTube jar. Without this
  // alias, the nested-webview guard treats the SetSID redirect as a
  // cross-domain navigation, opens it in a nested browser, and the main
  // webview never receives the redirect-back — the user gets stuck
  // looking "signed out" despite completing the SSO flow.
  'youtube.com': 'google.com',
  'youtu.be': 'google.com',
  'youtube-nocookie.com': 'google.com',
  'discordapp.com': 'discord.com',
  'discord.gg': 'discord.com',
  'hf.co': 'huggingface.co',
  'claude.ai': 'anthropic.com',
  'chatgpt.com': 'openai.com',
  // Regional Google domains
  'google.co.uk': 'google.com',
  'google.com.au': 'google.com',
  'google.co.jp': 'google.com',
  'google.co.in': 'google.com',
  'google.de': 'google.com',
  'google.fr': 'google.com',
  'google.es': 'google.com',
  'google.it': 'google.com',
  'google.nl': 'google.com',
  'google.pl': 'google.com',
  'google.ru': 'google.com',
  'google.com.br': 'google.com',
  'google.com.mx': 'google.com',
  'google.ca': 'google.com',
  'google.co.kr': 'google.com',
  'google.com.tw': 'google.com',
  'google.com.hk': 'google.com',
  'google.co.id': 'google.com',
  'google.co.th': 'google.com',
  'google.com.vn': 'google.com',
  'google.com.ph': 'google.com',
  'google.com.my': 'google.com',
  'google.com.sg': 'google.com',
  'google.co.nz': 'google.com',
  'google.co.za': 'google.com',
  'google.com.ar': 'google.com',
  'google.cl': 'google.com',
  'google.com.co': 'google.com',
  'google.com.tr': 'google.com',
  'google.co.il': 'google.com',
  'google.ae': 'google.com',
  'google.com.sa': 'google.com',
  'google.com.eg': 'google.com',
  'google.com.pk': 'google.com',
  'google.com.ng': 'google.com',
  'google.be': 'google.com',
  'google.at': 'google.com',
  'google.ch': 'google.com',
  'google.se': 'google.com',
  'google.no': 'google.com',
  'google.dk': 'google.com',
  'google.fi': 'google.com',
  'google.ie': 'google.com',
  'google.pt': 'google.com',
  'google.cz': 'google.com',
  'google.ro': 'google.com',
  'google.hu': 'google.com',
  'google.gr': 'google.com',
};

/// Normalizes a domain by applying aliases and extracting second-level domain.
/// Used for nested webview URL blocking - determines if navigation stays in same webview.
/// Handles multi-part TLDs like .co.uk, .com.au, etc.
/// Example: 'mail.google.com' -> 'google.com' (second-level)
/// Example: 'gmail.com' -> 'google.com' (alias)
/// Example: 'www.google.co.uk' -> 'google.com' (second-level extracted, then aliased)
String getNormalizedDomain(String url) {
  final host = extractDomain(url);

  if (_domainAliases.containsKey(host)) {
    return _domainAliases[host]!;
  }

  final secondLevel = getBaseDomain(url);

  if (_domainAliases.containsKey(secondLevel)) {
    return _domainAliases[secondLevel]!;
  }

  return secondLevel;
}
