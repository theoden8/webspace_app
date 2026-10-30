import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart' as intl;

import 'package:webspace/l10n/runtime/icu_message.dart';

typedef ArbRead = FutureOr<String> Function(String path);

/// Text a person reads in the app's own chrome: a message of the active
/// locale, which only [ArbMessages] makes, or data shown as it is
/// ([Localized.verbatim]). A parameter typed by it takes no string literal,
/// so English reaches the screen only through the ARB files (L10N-002).
extension type const Localized._(String _text) implements String {
  /// [value] shown as it is: data such as a host, a count or a name, never
  /// a sentence.
  const Localized.verbatim(String value) : _text = value;

  /// Whole messages one after another, separated [by] one of [Joined]'s.
  Localized.joined(Iterable<Localized> messages, {required Joined by})
    : _text = messages.join(by.separator);
}

/// What may stand between whole messages. Each keeps its own word order;
/// a free separator would let parts of one sentence be glued in English's.
enum Joined {
  paragraphs('\n\n'),
  lines('\n'),
  /// Names in a row, as a summary lists what is on.
  list(' · '),

  /// A term and its value or explanation ('Camera: Allowed'). English's
  /// colon in every locale: debt, lifted by a message per locale.
  term(': '),

  /// Whole sentences in one paragraph. English's space in every locale,
  /// where Chinese and Japanese write none: debt, as [term].
  sentences(' ');

  const Joined(this.separator);

  final String separator;
}

/// One shipped locale's messages, read from its ARB at run time rather than
/// compiled into the app (L10N-012).
class ArbMessages {
  ArbMessages._({required this.localeName, required this._sources});

  final String localeName;
  final Map<String, String> _sources;
  final Map<String, IcuMessage> _parsed = {};

  /// A message without placeholders, which tool/gen_l10n.dart has checked
  /// parses to its own text in every locale.
  Localized text(String key) {
    final source = _sources[key]!;
    assert(!source.contains('{'), '$key has placeholders; read it with format');
    return Localized._(source);
  }

  Localized format(String key, {required Map<String, Object> args}) =>
      Localized._((_parsed[key] ??= IcuMessage.parse(
        _sources[key]!,
      )).format(args: args, locale: localeName));

  /// How an ARB file is read: the asset bundle in the app, the checkout in tests.
  static ArbRead read = (path) => rootBundle.loadString(path, cache: false);

  static final Map<Locale, ArbMessages> _loaded = {};

  /// The messages of the shipped locale [locale] resolves to, read once. A
  /// synchronous [read] completes synchronously, so a test's first frame
  /// already has its text.
  static Future<ArbMessages> load(
    Locale locale, {
    required List<Locale> supported,
    required List<String> keys,
  }) {
    final shipped = _shippedFor(locale, supported: supported);
    final loaded = _loaded[shipped];
    if (loaded != null) return SynchronousFuture(loaded);
    final source = read('lib/l10n/app_$shipped.arb');
    if (source is String) {
      return SynchronousFuture(_parse(shipped, source: source, keys: keys));
    }
    return source.then((source) => _parse(shipped, source: source, keys: keys));
  }

  // The order gen_l10n's lookup used: the most specific shipped locale wins.
  static Locale _shippedFor(Locale locale, {required List<Locale> supported}) {
    for (final (script, country) in const [
      (true, true),
      (true, false),
      (false, true),
      (false, false),
    ]) {
      for (final candidate in supported) {
        if (candidate.languageCode == locale.languageCode &&
            candidate.scriptCode == (script ? locale.scriptCode : null) &&
            candidate.countryCode == (country ? locale.countryCode : null)) {
          return candidate;
        }
      }
    }
    throw StateError('no shipped locale for $locale');
  }

  static ArbMessages _parse(
    Locale shipped, {
    required String source,
    required List<String> keys,
  }) {
    final arb = jsonDecode(source) as Map<String, dynamic>;
    final sources = {
      for (final MapEntry(:key, :value) in arb.entries)
        if (!key.startsWith('@') && value is String) key: value,
    };
    assert(
      keys.every(sources.containsKey),
      'app_$shipped.arb lacks ${keys.where((key) => !sources.containsKey(key)).join(', ')}',
    );
    return _loaded[shipped] = ArbMessages._(
      localeName: intl.Intl.canonicalizedLocale(shipped.toString()),
      sources: sources,
    );
  }
}
