// Fills missing translations in locale ARB files from the English template
// using an LLM. This is the localization "runner" (LOC-004): translated ARBs
// are reproducible from `lib/l10n/app_en.arb` + this script, so they are
// build derivatives. It is additive only -- existing values are never
// overwritten, so human corrections survive re-runs.
//
// Usage:
//   dart run tool/translate_arb.dart <locale> [<locale> ...]
//   dart run tool/translate_arb.dart de fr es
//
// Configuration (env), OpenAI-compatible chat-completions endpoint. Point
// the base URL at any compatible server (OpenAI, a local gateway, etc.):
//   WEBSPACE_TRANSLATE_API_KEY    required
//   WEBSPACE_TRANSLATE_BASE_URL   default https://api.openai.com/v1
//   WEBSPACE_TRANSLATE_MODEL      default gpt-4o-mini
//
// Dry run (no network; prints which keys would be translated):
//   dart run tool/translate_arb.dart --dry-run de

import 'dart:convert';
import 'dart:io';

const _arbDir = 'lib/l10n';
const _templateFile = '$_arbDir/app_en.arb';

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  final locales = args.where((a) => !a.startsWith('-')).toList();
  if (locales.isEmpty) {
    stderr.writeln('usage: dart run tool/translate_arb.dart [--dry-run] '
        '<locale> [<locale> ...]');
    exit(2);
  }

  final template = _readArb(_templateFile);
  final keys = template.keys.where((k) => !k.startsWith('@')).toList();

  for (final locale in locales) {
    final path = '$_arbDir/app_$locale.arb';
    final existing = File(path).existsSync() ? _readArb(path) : <String, dynamic>{};

    final missing = [
      for (final k in keys)
        if (!existing.containsKey(k) || (existing[k] as String?)?.isEmpty == true) k
    ];

    if (missing.isEmpty) {
      stdout.writeln('[$locale] up to date (${keys.length} keys).');
      continue;
    }
    stdout.writeln('[$locale] ${missing.length} key(s) to translate.');

    if (dryRun) {
      for (final k in missing) stdout.writeln('  + $k');
      continue;
    }

    final source = {for (final k in missing) k: template[k] as String};
    final translated = await _translate(source, locale);

    final out = <String, dynamic>{'@@locale': locale};
    for (final k in keys) {
      final value = translated[k] ?? existing[k];
      if (value != null) out[k] = value;
    }
    _writeArb(path, out);
    stdout.writeln('[$locale] wrote $path.');
  }
}

Map<String, dynamic> _readArb(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

void _writeArb(String path, Map<String, dynamic> data) {
  const encoder = JsonEncoder.withIndent('  ');
  File(path).writeAsStringSync('${encoder.convert(data)}\n');
}

/// Sends the untranslated key->English map and returns key->translation.
/// Placeholder tokens like {host} MUST be preserved verbatim; the prompt
/// enforces this and `l10n_coverage_test.dart` verifies it after the fact.
Future<Map<String, String>> _translate(
  Map<String, String> source,
  String locale,
) async {
  final apiKey = Platform.environment['WEBSPACE_TRANSLATE_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('WEBSPACE_TRANSLATE_API_KEY is not set.');
    exit(1);
  }
  final baseUrl = Platform.environment['WEBSPACE_TRANSLATE_BASE_URL'] ??
      'https://api.openai.com/v1';
  final model =
      Platform.environment['WEBSPACE_TRANSLATE_MODEL'] ?? 'gpt-4o-mini';

  final prompt = '''
Translate the JSON values below into locale "$locale" for a mobile web browser UI.
Rules:
- Return ONLY a JSON object mapping each original key to its translation.
- Preserve every placeholder token exactly, e.g. {host}, {port}, {count}. Do not translate or reorder the token names.
- Keep ICU plural/select syntax intact if present.
- Match the original tone: short, plain UI strings.
- Do not add or remove keys.

JSON to translate:
${const JsonEncoder.withIndent('  ').convert(source)}
''';

  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$baseUrl/chat/completions'));
    req.headers
      ..set('content-type', 'application/json')
      ..set('authorization', 'Bearer $apiKey');
    req.add(utf8.encode(jsonEncode({
      'model': model,
      'temperature': 0,
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'system',
          'content': 'You are a professional software localizer. '
              'You output only valid JSON.',
        },
        {'role': 'user', 'content': prompt},
      ],
    })));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      stderr.writeln('translation API error ${resp.statusCode}: $body');
      exit(1);
    }
    final content =
        jsonDecode(body)['choices'][0]['message']['content'] as String;
    final map = (jsonDecode(content) as Map).cast<String, dynamic>();
    return map.map((k, v) => MapEntry(k, v.toString()));
  } finally {
    client.close();
  }
}
