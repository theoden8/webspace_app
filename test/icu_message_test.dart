import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/l10n/runtime/arb_messages.dart';
import 'package:webspace/l10n/runtime/icu_message.dart';

String format(
  String source, {
  Map<String, Object> args = const {},
  String locale = 'en',
}) => IcuMessage.parse(source).format(args: args, locale: locale);

// LOC-012: translations are read from the ARB at run time; these hold the
// grammar and plural rules gen_l10n compiled in before.
void main() {
  group('IcuMessage', () {
    test('text and arguments', () {
      expect(format('Plain text, no braces.'), 'Plain text, no braces.');
      expect(format(''), '');
      expect(
        format('{host}:{ port }', args: {'host': 'example.com', 'port': 443}),
        'example.com:443',
      );
      expect(IcuMessage.parse('{host}:{port}').arguments, {'host', 'port'});
    });

    test('plural folds =0/=1/=2 into the CLDR forms, the later case winning', () {
      const source =
          '{count, plural, =1{exactly one} one{CLDR one} =0{none} other{{count} items}}';
      expect(format(source, args: {'count': 1}), 'CLDR one');
      expect(format(source, args: {'count': 0}), 'none');
      expect(format(source, args: {'count': 7}), '7 items');
      expect(IcuMessage.parse(source).pluralArguments, {'count'});
    });

    test(
      'plural picks the locale\'s CLDR form, with text and arguments around it',
      () {
        const source =
            '{name} · {count, plural, =1{1 karta} few{{count} karty} many{{count} kart} other{{count} kart}}';
        String pl(int count) => format(
          source,
          args: {'name': 'Praca', 'count': count},
          locale: 'pl',
        );
        expect(pl(1), 'Praca · 1 karta');
        expect(pl(3), 'Praca · 3 karty');
        expect(pl(5), 'Praca · 5 kart');
        expect(pl(22), 'Praca · 22 karty');
      },
    );

    test('select', () {
      const source = '{kind, select, socks{SOCKS proxy} other{HTTP proxy}}';
      expect(format(source, args: {'kind': 'socks'}), 'SOCKS proxy');
      expect(format(source, args: {'kind': 'https'}), 'HTTP proxy');
      expect(IcuMessage.parse(source).pluralArguments, isEmpty);
    });

    test('malformed messages fail to parse', () {
      for (final source in [
        'a } b',
        'unclosed {name',
        '{count, plural, one{1 item}}',
        '{count, plural, =3{three} other{many}}',
        '{when, date, short}',
        '{count, plural, other{{count} items}',
      ]) {
        expect(
          () => IcuMessage.parse(source),
          throwsFormatException,
          reason: source,
        );
      }
    });
  });

  group('ArbMessages', () {
    Future<String> localeNameOf(Locale locale) async =>
        (await AppLocalizations.delegate.load(locale)).localeName;

    test('a locale loads the most specific shipped ARB', () async {
      expect(await localeNameOf(const Locale('pt', 'BR')), 'pt_BR');
      expect(await localeNameOf(const Locale('pt', 'PT')), 'pt');
      expect(await localeNameOf(const Locale('en', 'US')), 'en');
      expect(
        await localeNameOf(
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
        ),
        'zh',
      );
      expect(
        AppLocalizations.delegate.isSupported(const Locale('xx')),
        isFalse,
      );
    });

    test(
      'a synchronous read loads synchronously, an asset read does not',
      () async {
        expect(
          AppLocalizations.delegate.load(const Locale('de')),
          isA<SynchronousFuture<AppLocalizations>>(),
        );
        final read = ArbMessages.read;
        addTearDown(() => ArbMessages.read = read);
        ArbMessages.read = (path) => File(path).readAsString();
        final loading = AppLocalizations.delegate.load(const Locale('fr'));
        expect(loading, isNot(isA<SynchronousFuture<AppLocalizations>>()));
        expect((await loading).localeName, 'fr');
      },
    );
  });
}
