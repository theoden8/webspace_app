import 'package:intl/intl.dart' as intl;

/// One ARB message in the grammar gen_l10n accepted without quote escaping:
/// text, `{arg}`, and `{arg, plural, ...}` or `{arg, select, ...}` cases.
class IcuMessage {
  IcuMessage._(this._parts);

  /// Throws a [FormatException] pointing at the offending character.
  factory IcuMessage.parse(String source) =>
      IcuMessage._(_Parser(source).message(nested: false));

  final List<_Part> _parts;

  /// Every argument the message reads, plural selectors included.
  Set<String> get arguments => {
    for (final part in _parts) ..._argumentsOf(part),
  };

  /// The arguments a plural selects on, which must be numbers.
  Set<String> get pluralArguments => {
    for (final part in _parts) ..._pluralArgumentsOf(part),
  };

  String format({required Map<String, Object> args, required String locale}) =>
      _join(_parts, args: args, locale: locale);
}

enum _PluralForm { zero, one, two, few, many, other }

// gen_l10n folds an exact `=0`/`=1`/`=2` into the matching CLDR form, so
// `=1` and `one` are one case and the later of the two wins.
const _pluralSelectors = {
  '=0': _PluralForm.zero,
  '=1': _PluralForm.one,
  '=2': _PluralForm.two,
  'zero': _PluralForm.zero,
  'one': _PluralForm.one,
  'two': _PluralForm.two,
  'few': _PluralForm.few,
  'many': _PluralForm.many,
  'other': _PluralForm.other,
};

sealed class _Part {}

final class _Text extends _Part {
  _Text(this.text);
  final String text;
}

final class _Arg extends _Part {
  _Arg(this.name);
  final String name;
}

final class _Plural extends _Part {
  _Plural(this.name, {required this.forms});
  final String name;
  final Map<_PluralForm, List<_Part>> forms;
}

final class _Select extends _Part {
  _Select(this.name, {required this.cases});
  final String name;
  final Map<String, List<_Part>> cases;
}

Iterable<String> _argumentsOf(_Part part) => switch (part) {
  _Text() => const [],
  _Arg(:final name) => [name],
  _Plural(:final name, :final forms) => [
    name,
    for (final parts in forms.values) ...parts.expand(_argumentsOf),
  ],
  _Select(:final name, :final cases) => [
    name,
    for (final parts in cases.values) ...parts.expand(_argumentsOf),
  ],
};

Iterable<String> _pluralArgumentsOf(_Part part) => switch (part) {
  _Text() || _Arg() => const [],
  _Plural(:final name, :final forms) => [
    name,
    for (final parts in forms.values) ...parts.expand(_pluralArgumentsOf),
  ],
  _Select(:final cases) => [
    for (final parts in cases.values) ...parts.expand(_pluralArgumentsOf),
  ],
};

String _join(
  List<_Part> parts, {
  required Map<String, Object> args,
  required String locale,
}) {
  if (parts case [_Text(:final text)]) return text;
  String? form(List<_Part>? parts) =>
      parts == null ? null : _join(parts, args: args, locale: locale);
  final out = StringBuffer();
  for (final part in parts) {
    out.write(switch (part) {
      _Text(:final text) => text,
      _Arg(:final name) => _argument(args, name: name),
      _Plural(:final name, :final forms) => intl.Intl.pluralLogic(
        _argument(args, name: name) as num,
        locale: locale,
        zero: form(forms[_PluralForm.zero]),
        one: form(forms[_PluralForm.one]),
        two: form(forms[_PluralForm.two]),
        few: form(forms[_PluralForm.few]),
        many: form(forms[_PluralForm.many]),
        other: form(forms[_PluralForm.other])!,
      ),
      _Select(:final name, :final cases) => intl.Intl.selectLogic(
        _argument(args, name: name),
        {for (final MapEntry(:key, :value) in cases.entries) key: form(value)!},
      ),
    });
  }
  return out.toString();
}

Object _argument(Map<String, Object> args, {required String name}) {
  assert(
    args.containsKey(name),
    'the message reads {$name}, which the caller did not pass',
  );
  return args[name]!;
}

class _Parser {
  _Parser(this.source);

  final String source;
  int _at = 0;

  static final _identifier = RegExp(r'[a-zA-Z0-9|_]+');
  static final _number = RegExp(r'[0-9]+');
  static final _whitespace = RegExp(r'\s*');
  static final _brace = RegExp('[{}]');

  List<_Part> message({required bool nested}) {
    final parts = <_Part>[];
    while (_at < source.length) {
      final char = source[_at];
      if (char == '}') {
        if (!nested) throw _error('unmatched "}"');
        return parts;
      }
      if (char == '{') {
        parts.add(_placeholder());
        continue;
      }
      final end = _nextBrace();
      parts.add(_Text(source.substring(_at, end)));
      _at = end;
    }
    if (nested) throw _error('unclosed "{"');
    return parts;
  }

  _Part _placeholder() {
    _expect('{');
    final name = _token(_identifier, what: 'an argument name');
    if (_peek() == '}') {
      _expect('}');
      return _Arg(name);
    }
    _expect(',');
    final kind = _token(_identifier, what: '"plural" or "select"');
    _expect(',');
    final _Part part;
    switch (kind) {
      case 'plural':
        final forms = <_PluralForm, List<_Part>>{};
        for (final (selector, parts) in _cases()) {
          final form =
              _pluralSelectors[selector] ??
              (throw _error('"$selector" is not a plural case'));
          forms[form] = parts;
        }
        if (!forms.containsKey(_PluralForm.other)) {
          throw _error('plural {$name} has no "other" case');
        }
        part = _Plural(name, forms: forms);
      case 'select':
        part = _Select(
          name,
          cases: {for (final (selector, parts) in _cases()) selector: parts},
        );
      default:
        throw _error('"$kind" is not "plural" or "select"');
    }
    _expect('}');
    return part;
  }

  List<(String, List<_Part>)> _cases() {
    final cases = <(String, List<_Part>)>[];
    while (_peek() != '}') {
      final exact = _peek() == '=';
      if (exact) _expect('=');
      final selector = _token(
        exact ? _number : _identifier,
        what: 'a case name',
      );
      _expect('{');
      cases.add((exact ? '=$selector' : selector, message(nested: true)));
      _expect('}');
    }
    if (cases.isEmpty) throw _error('no cases');
    return cases;
  }

  int _nextBrace() {
    final next = source.indexOf(_brace, _at);
    return next < 0 ? source.length : next;
  }

  String? _peek() {
    _skipWhitespace();
    return _at < source.length ? source[_at] : null;
  }

  void _skipWhitespace() => _at = _whitespace.matchAsPrefix(source, _at)!.end;

  void _expect(String char) {
    if (_peek() != char) throw _error('expected "$char"');
    _at++;
  }

  String _token(RegExp pattern, {required String what}) {
    _skipWhitespace();
    final match =
        pattern.matchAsPrefix(source, _at) ?? (throw _error('expected $what'));
    _at = match.end;
    return match[0]!;
  }

  FormatException _error(String problem) =>
      FormatException(problem, source, _at);
}
