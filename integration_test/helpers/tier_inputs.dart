/// What the script that runs an integration test tells it about where it runs
/// (`--input KEY=VALUE` in scripts/lib/android_tier.sh), each input named once
/// here. A launch carries them as `KEY=VALUE,...`: in the bundled app's launch
/// string (scripts/integration_bundle.sh), or in one define when the file runs
/// its own `flutter test`. A key no input names fails the launch, where a
/// misspelled `--dart-define` read as unset and skipped its tier, green.
enum TierInput {
  tvTier('WS_TV_TIER'),
  desktopTier('WS_DESKTOP_TIER'),
  passkeyGate('PASSKEY_GATE'),
  passkeyPhase('PASSKEY_GATE_PHASE'),
  passkeyRp('PASSKEY_GATE_RP');

  const TierInput(this.key);

  final String key;

  String? get value => _given[this];

  bool get on => value == 'true';

  /// The inputs the bundled app was launched with.
  static void take(Iterable<String> pairs) => _given = _parse(pairs);

  static Map<TierInput, String> _given = _parse(
    const String.fromEnvironment('WEBSPACE_INTEGRATION_INPUTS').split(','),
  );

  static Map<TierInput, String> _parse(Iterable<String> pairs) {
    final given = <TierInput, String>{};
    for (final pair in pairs.where((p) => p.isNotEmpty)) {
      if (pair.split('=') case [final key, final value]) {
        given[_named(key)] = value;
      } else {
        throw ArgumentError.value(pair, 'input', 'is not KEY=VALUE');
      }
    }
    return given;
  }

  static TierInput _named(String key) => values.firstWhere(
        (input) => input.key == key,
        orElse: () => throw ArgumentError.value(key, 'input', 'names no TierInput'),
      );
}
