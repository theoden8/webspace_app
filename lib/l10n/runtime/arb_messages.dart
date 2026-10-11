import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart' as intl;

import 'package:webspace/l10n/runtime/icu_message.dart';

typedef ArbRead = FutureOr<String> Function(String path);

/// One shipped locale's messages, read from its ARB at run time rather than
/// compiled into the app (LOC-012).
class ArbMessages {
  ArbMessages._({
    required this.localeName,
    required Map<String, IcuMessage> messages,
  }) : _messages = messages;

  final String localeName;
  final Map<String, IcuMessage> _messages;

  String text(String key) => format(key, args: const {});

  String format(String key, {required Map<String, Object> args}) =>
      _messages[key]!.format(args: args, locale: localeName);

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
    final messages = {
      for (final MapEntry(:key, :value) in arb.entries)
        if (!key.startsWith('@') && value is String)
          key: IcuMessage.parse(value),
    };
    assert(
      keys.every(messages.containsKey),
      'app_$shipped.arb lacks ${keys.where((key) => !messages.containsKey(key)).join(', ')}',
    );
    return _loaded[shipped] = ArbMessages._(
      localeName: intl.Intl.canonicalizedLocale(shipped.toString()),
      messages: messages,
    );
  }
}
