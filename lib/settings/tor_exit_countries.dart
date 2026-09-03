/// Countries offered as a Tor exit pin (TOR-014).
///
/// A shortlist, not ISO 3166. Pinning a country with no usable exit is a
/// dead end by design — `StrictNodes 1` means the request fails rather
/// than leaving from somewhere else — so offering all ~250 codes would be
/// offering mostly dead ends. These are the countries that carry a
/// durable share of exit capacity.
///
/// The list is curated and will drift as the network does. That is
/// tolerable in one direction only: a country that loses its exits fails
/// visibly under `StrictNodes` instead of silently rerouting, which is
/// the behaviour TOR-014 exists to guarantee. tor exposes no way to
/// enumerate this — `GETINFO ip-to-country/<ip>` maps one address, and
/// deriving the set would mean walking the whole consensus over the
/// control port.
///
/// Names are endonyms, in the most widely spoken official language of the
/// country and its own script, matching [kLanguageNativeNames] in
/// `app_locale.dart`. That is what keeps this out of the ARB files: one
/// name per country rather than one per country per UI locale. The ISO
/// code is always shown alongside, so an unfamiliar endonym is still
/// identifiable.
library;

/// One selectable exit country.
class TorExitCountry {
  const TorExitCountry(this.code, this.endonym);

  /// ISO 3166-1 alpha-2, lowercase — the form `torExitCountry` stores and
  /// `exitNodesValue` wraps into tor's `{cc}` syntax.
  final String code;

  /// The country's own name for itself.
  final String endonym;

  /// Regional-indicator pair for [code], which renders as the flag on
  /// every platform that has the glyphs and as two letters where it does
  /// not. Computed rather than stored so it cannot fall out of sync.
  String get flag {
    if (code.length != 2) return '';
    const base = 0x1F1E6; // REGIONAL INDICATOR SYMBOL LETTER A
    final upper = code.toUpperCase();
    return String.fromCharCodes([
      base + upper.codeUnitAt(0) - 0x41,
      base + upper.codeUnitAt(1) - 0x41,
    ]);
  }

  /// `🇩🇪  Deutschland (DE)` — what the picker row shows.
  String get label => '$flag  $endonym (${code.toUpperCase()})';
}

/// Sorted by endonym so the picker has a stable order that does not
/// depend on the UI locale.
const List<TorExitCountry> kTorExitCountries = [
  TorExitCountry('au', 'Australia'),
  TorExitCountry('at', 'Österreich'),
  TorExitCountry('be', 'België'),
  TorExitCountry('br', 'Brasil'),
  TorExitCountry('bg', 'България'),
  TorExitCountry('ca', 'Canada'),
  TorExitCountry('hr', 'Hrvatska'),
  TorExitCountry('cz', 'Česko'),
  TorExitCountry('dk', 'Danmark'),
  TorExitCountry('ee', 'Eesti'),
  TorExitCountry('fi', 'Suomi'),
  TorExitCountry('fr', 'France'),
  TorExitCountry('de', 'Deutschland'),
  TorExitCountry('gr', 'Ελλάδα'),
  TorExitCountry('hk', '香港'),
  TorExitCountry('hu', 'Magyarország'),
  TorExitCountry('is', 'Ísland'),
  TorExitCountry('ie', 'Ireland'),
  TorExitCountry('il', 'ישראל'),
  TorExitCountry('it', 'Italia'),
  TorExitCountry('jp', '日本'),
  TorExitCountry('lv', 'Latvija'),
  TorExitCountry('lt', 'Lietuva'),
  TorExitCountry('lu', 'Luxembourg'),
  TorExitCountry('md', 'Moldova'),
  TorExitCountry('nl', 'Nederland'),
  TorExitCountry('nz', 'New Zealand'),
  TorExitCountry('no', 'Norge'),
  TorExitCountry('pl', 'Polska'),
  TorExitCountry('pt', 'Portugal'),
  TorExitCountry('ro', 'România'),
  TorExitCountry('rs', 'Србија'),
  TorExitCountry('sg', 'Singapore'),
  TorExitCountry('sk', 'Slovensko'),
  TorExitCountry('si', 'Slovenija'),
  TorExitCountry('za', 'South Africa'),
  TorExitCountry('es', 'España'),
  TorExitCountry('se', 'Sverige'),
  TorExitCountry('ch', 'Schweiz'),
  TorExitCountry('ua', 'Україна'),
  TorExitCountry('gb', 'United Kingdom'),
  TorExitCountry('us', 'United States'),
];

/// The entry for [code], or null when the pin names a country the
/// shortlist does not carry.
///
/// A stored pin is not required to be in the list: it can arrive from a
/// settings backup written by a build with a longer list, or be
/// hand-edited. Such a pin stays in force — it is a valid `{cc}` and tor
/// will honour it — so the caller shows the bare code rather than
/// dropping the user's setting.
TorExitCountry? torExitCountryFor(String? code) {
  final cc = code?.trim().toLowerCase();
  if (cc == null || cc.isEmpty) return null;
  for (final c in kTorExitCountries) {
    if (c.code == cc) return c;
  }
  return null;
}
