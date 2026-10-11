// Generates lib/l10n/gen/localizations.dart, the typed API over the ARB
// files, from the template lib/l10n/app_en.arb. The translations themselves
// stay data: the app reads the active locale's ARB from its assets (LOC-012).
// Every shipped ARB is parsed here so a broken translation fails the build,
// not the screen that shows it.
//
// The native builds run this before Dart is compiled (Gradle, Xcode, CMake);
// `flutter test`, `flutter analyze` and a web build need it run by hand after
// `pub get`: `fvm dart tool/gen_l10n.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:webspace/l10n/runtime/icu_message.dart';

const _template = 'en';
// Not gen_l10n's app_localizations.dart: a .dart_tool kept from a gen_l10n
// build still lists that path as Flutter's own output, and Flutter deletes it
// on the next build once its l10n step stops running.
const _output = 'localizations.dart';
const _placeholderTypes = {'String', 'int', 'num', 'double', 'Object'};
const _numberTypes = {'int', 'num', 'double'};
final _key = RegExp(r'^[a-z][a-zA-Z0-9_]*$');
final _arbName = RegExp(r'^app_(.+)\.arb$');

void main() {
  final l10n = Directory.fromUri(Platform.script.resolve('../lib/l10n/'));
  final problems = <String>[];

  final arbs = {
    for (final file in l10n.listSync().whereType<File>())
      if (_arbName.firstMatch(file.uri.pathSegments.last) case final match?)
        match[1]!: jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
  };
  final template =
      arbs[_template] ??
      (throw StateError('no app_$_template.arb in ${l10n.path}'));
  final messages = [
    for (final MapEntry(:key, :value) in template.entries)
      if (!key.startsWith('@'))
        _templateMessage(
          key,
          value: value,
          metadata: template['@$key'],
          problems: problems,
        ),
  ].nonNulls.toList();

  final tags = arbs.keys.toList()..sort();
  for (final tag in tags) {
    final arb = arbs[tag]!;
    final keys = {
      for (final key in arb.keys)
        if (!key.startsWith('@')) key,
    };
    for (final message in messages) {
      final value = arb[message.key];
      if (value is! String) {
        problems.add('app_$tag.arb: ${message.key} is missing');
        continue;
      }
      final parsed = _parse(
        value,
        where: 'app_$tag.arb: ${message.key}',
        problems: problems,
      );
      final undeclared =
          parsed?.arguments.difference(message.placeholderNames) ?? const {};
      if (undeclared.isNotEmpty) {
        problems.add(
          'app_$tag.arb: ${message.key} reads {${undeclared.join('}, {')}}, which app_en.arb does not declare',
        );
      }
    }
    final extra = keys.difference({
      for (final message in messages) message.key,
    });
    if (extra.isNotEmpty) {
      problems.add('app_$tag.arb: ${extra.join(', ')} not in app_en.arb');
    }
  }

  if (problems.isNotEmpty) {
    stderr.writeln(
      'tool/gen_l10n.dart: ${problems.length} problem(s) in lib/l10n/*.arb:',
    );
    for (final problem in problems) {
      stderr.writeln('  $problem');
    }
    exit(1);
  }

  final gen = Directory.fromUri(l10n.uri.resolve('gen/'))..createSync();
  for (final stale in gen.listSync()) {
    if (stale.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty) !=
        _output) {
      stale.deleteSync(recursive: true);
    }
  }
  final out = File.fromUri(gen.uri.resolve(_output));
  final source = _render(messages, tags: tags);
  if (!out.existsSync() || out.readAsStringSync() != source) {
    out.writeAsStringSync(source);
  }
}

class _Placeholder {
  _Placeholder({required this.name, required this.type});
  final String name;
  final String type;
}

class _Message {
  _Message({
    required this.key,
    required this.english,
    required this.description,
    required this.placeholders,
  });
  final String key;
  final String english;
  final String description;
  final List<_Placeholder> placeholders;

  Set<String> get placeholderNames => {
    for (final placeholder in placeholders) placeholder.name,
  };
}

_Message? _templateMessage(
  String key, {
  required Object? value,
  required Object? metadata,
  required List<String> problems,
}) {
  final where = 'app_en.arb: $key';
  if (!_key.hasMatch(key)) {
    problems.add('$where is not a Dart identifier');
    return null;
  }
  if (value is! String) {
    problems.add('$where is not a string');
    return null;
  }
  final meta = _object(metadata);
  final placeholders = <_Placeholder>[];
  for (final MapEntry(key: name, :value) in _object(
    meta['placeholders'],
  ).entries) {
    final spec = _object(value);
    final type = spec['type'] as String? ?? 'Object';
    if (!_placeholderTypes.contains(type)) {
      problems.add(
        '$where: {$name} has type $type; supported: ${_placeholderTypes.join(', ')}',
      );
    }
    for (final unsupported in [
      'format',
      'optionalParameters',
      'isCustomDateFormat',
    ]) {
      if (spec.containsKey(unsupported)) {
        problems.add(
          '$where: {$name} sets "$unsupported", which the runtime does not apply',
        );
      }
    }
    placeholders.add(_Placeholder(name: name, type: type));
  }
  final message = _Message(
    key: key,
    english: value,
    description: meta['description'] as String? ?? '',
    placeholders: placeholders,
  );
  final parsed = _parse(value, where: where, problems: problems);
  if (parsed != null) {
    final undeclared = parsed.arguments.difference(message.placeholderNames);
    if (undeclared.isNotEmpty) {
      problems.add(
        '$where reads {${undeclared.join('}, {')}} without declaring it in @$key.placeholders',
      );
    }
    for (final placeholder in placeholders) {
      if (parsed.pluralArguments.contains(placeholder.name) &&
          !_numberTypes.contains(placeholder.type)) {
        problems.add(
          '$where: plural {${placeholder.name}} must be a number, not ${placeholder.type}',
        );
      }
    }
  }
  return message;
}

Map<String, dynamic> _object(Object? json) => switch (json) {
  final Map<String, dynamic> map => map,
  _ => const {},
};

IcuMessage? _parse(
  String value, {
  required String where,
  required List<String> problems,
}) {
  try {
    return IcuMessage.parse(value);
  } on FormatException catch (error) {
    problems.add('$where: ${error.message} at offset ${error.offset}');
    return null;
  }
}

String _localeExpression(String tag) {
  final parts = tag.split('_');
  final script = parts.length > 1 && parts[1].length == 4 ? parts[1] : null;
  final country = parts.skip(script == null ? 1 : 2).firstOrNull;
  if (script == null) {
    return country == null
        ? "Locale('${parts[0]}')"
        : "Locale('${parts[0]}', '$country')";
  }
  return "Locale.fromSubtags(languageCode: '${parts[0]}', scriptCode: '$script'"
      "${country == null ? '' : ", countryCode: '$country'"})";
}

String _docComment(_Message message) => [
  ...message.description.split('\n'),
  '',
  'In en, this message translates to:',
  ...'**\'${message.english}\'**'.split('\n'),
].map((line) => line.isEmpty ? '  ///' : '  /// $line').join('\n');

String _member(_Message message) {
  if (message.placeholders.isEmpty) {
    return "  String get ${message.key} => _messages.text('${message.key}');";
  }
  final parameters = message.placeholders
      .map((p) => '${p.type} ${p.name}')
      .join(', ');
  final args = message.placeholders
      .map((p) => "'${p.name}': ${p.name}")
      .join(', ');
  return "  String ${message.key}($parameters) =>\n"
      "      _messages.format('${message.key}', args: {$args});";
}

String _render(List<_Message> messages, {required List<String> tags}) =>
    '''
// Generated by tool/gen_l10n.dart from lib/l10n/app_en.arb. Do not edit.
// ignore_for_file: type=lint

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:webspace/l10n/runtime/arb_messages.dart';

class AppLocalizations {
  AppLocalizations._(this._messages);

  final ArbMessages _messages;

  String get localeName => _messages.localeName;

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations)!;

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  static const List<Locale> supportedLocales = <Locale>[
${tags.map((tag) => '    ${_localeExpression(tag)},').join('\n')}
  ];

  static const List<String> _keys = <String>[
${messages.map((message) => "    '${message.key}',").join('\n')}
  ];

${messages.map((message) => '${_docComment(message)}\n${_member(message)}').join('\n\n')}
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) => ArbMessages.load(
        locale,
        supported: AppLocalizations.supportedLocales,
        keys: AppLocalizations._keys,
      ).then(AppLocalizations._);

  @override
  bool isSupported(Locale locale) =>
      AppLocalizations.supportedLocales.any((supported) => supported.languageCode == locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
''';
