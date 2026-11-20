/// An SVG's `<style>` sheet written into its elements' `style` attributes,
/// with the `prefers-color-scheme` rules for [dark] applied (ICON-005).
///
/// flutter_svg ignores `<style>` elements: a fill set there draws as the
/// default black, and the dark variant a site ships is never seen. Inline
/// `style` attributes it does read, so the sheet is folded into them before
/// the icon is drawn.
///
/// The SVG is untrusted. This is a string transform and runs nothing: it
/// reads selectors of one element (`path`, `.cls`, `#id`, `path.cls`, `*`,
/// comma lists), plain declarations and `@media (prefers-color-scheme: ...)`
/// blocks, and skips any other selector or at-rule. Specificity is CSS's
/// (id, class, type), then sheet order; an element's own `style` wins over
/// the sheet. An SVG over [maxLength], or with no `<style>`, comes back as
/// it was.
String inlineSvgStyles(String svg, {required bool dark}) {
  if (svg.length > maxLength) return svg;
  final sheets = _styleElement.allMatches(svg).toList();
  if (sheets.isEmpty) return svg;
  final rules = <_Rule>[];
  for (final sheet in sheets) {
    _parse(_stripCdata(sheet.group(1)!), dark: dark, into: rules);
  }
  final withoutSheets = svg.replaceAll(_styleElement, '');
  if (rules.isEmpty) return withoutSheets;
  return withoutSheets.replaceAllMapped(_startTag, (m) {
    final name = m.group(1)!;
    if (name.startsWith('/')) return m.group(0)!;
    final attrs = m.group(2) ?? '';
    final end = m.group(3)!;
    final id = _attr(attrs, name: 'id');
    final classes = (_attr(attrs, name: 'class') ?? '')
        .split(RegExp(r'\s+'))
        .where((c) => c.isNotEmpty)
        .toSet();
    final matched = [
      for (final r in rules)
        if (r.selector.matches(name: name, id: id, classes: classes)) r,
    ]..sort((a, b) {
        final s = a.selector.specificity.compareTo(b.selector.specificity);
        return s != 0 ? s : a.order.compareTo(b.order);
      });
    if (matched.isEmpty) return m.group(0)!;
    final sheetStyle = matched.map((r) => r.declarations).join(';');
    final own = _attr(attrs, name: 'style');
    final style = own == null ? sheetStyle : '$sheetStyle;$own';
    final rest = own == null
        ? attrs
        : attrs.replaceFirst(_attrPattern('style'), '');
    return '<$name$rest style="${_escape(style)}"$end';
  });
}

/// The longest SVG the inliner reads; an icon past it is drawn as it is.
const maxLength = 256 * 1024;

final _styleElement =
    RegExp(r'<style\b[^>]*>([\s\S]*?)</style\s*>', caseSensitive: false);
final _startTag = RegExp(r'<(/?[A-Za-z][\w:.-]*)(\s[^<>]*?)?(\s*/?>)');

RegExp _attrPattern(String name) =>
    RegExp('\\s$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')');

String? _attr(String attrs, {required String name}) {
  final m = _attrPattern(name).firstMatch(attrs);
  return m == null ? null : (m.group(2) ?? m.group(3));
}

String _escape(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');

String _stripCdata(String css) =>
    css.replaceAll('<![CDATA[', '').replaceAll(']]>', '');

final class _Rule {
  _Rule({required this.selector, required this.declarations, required this.order});
  final _Selector selector;
  final String declarations;
  final int order;
}

/// One element's selector: an optional type, an optional id, any classes.
final class _Selector {
  _Selector({required this.type, required this.id, required this.classes});
  final String? type;
  final String? id;
  final Set<String> classes;

  static final _shape =
      RegExp(r'^(\*|[A-Za-z][\w-]*)?((?:[.#][A-Za-z_][\w-]*)*)$');
  static final _part = RegExp(r'([.#])([A-Za-z_][\w-]*)');

  /// Null for a selector this reads no further than one element of.
  static _Selector? parse(String text) {
    final m = _shape.firstMatch(text.trim());
    if (m == null || text.trim().isEmpty) return null;
    final type = m.group(1);
    String? id;
    final classes = <String>{};
    for (final p in _part.allMatches(m.group(2) ?? '')) {
      if (p.group(1) == '#') {
        if (id != null) return null;
        id = p.group(2);
      } else {
        classes.add(p.group(2)!);
      }
    }
    return _Selector(type: type == '*' ? null : type, id: id, classes: classes);
  }

  int get specificity =>
      (id == null ? 0 : 10000) + classes.length * 100 + (type == null ? 0 : 1);

  bool matches({required String name, required String? id, required Set<String> classes}) =>
      (type == null || type == name) &&
      (this.id == null || this.id == id) &&
      this.classes.every(classes.contains);
}

final _comment = RegExp(r'/\*[\s\S]*?\*/');
final _darkQuery = RegExp(r'prefers-color-scheme\s*:\s*dark');
final _lightQuery = RegExp(r'prefers-color-scheme\s*:\s*light');

void _parse(String css, {required bool dark, required List<_Rule> into}) {
  final text = css.replaceAll(_comment, '');
  var at = 0;
  while (at < text.length) {
    final open = text.indexOf('{', at);
    if (open < 0) return;
    final head = text.substring(at, open).trim();
    if (head.startsWith('@')) {
      final close = _matchingBrace(text, open: open);
      if (close < 0) return;
      final applies = head.startsWith('@media') &&
          (dark ? _darkQuery.hasMatch(head) : _lightQuery.hasMatch(head)) &&
          !(dark ? _lightQuery.hasMatch(head) : _darkQuery.hasMatch(head));
      if (applies) _parse(text.substring(open + 1, close), dark: dark, into: into);
      at = close + 1;
      continue;
    }
    final close = text.indexOf('}', open);
    if (close < 0) return;
    final declarations = text
        .substring(open + 1, close)
        .split(';')
        .map((d) => d.trim())
        .where((d) => d.contains(':') && !d.contains('<'))
        .join(';');
    if (declarations.isNotEmpty) {
      for (final part in head.split(',')) {
        if (_Selector.parse(part) case final selector?) {
          into.add(_Rule(selector: selector, declarations: declarations, order: into.length));
        }
      }
    }
    at = close + 1;
  }
}

int _matchingBrace(String text, {required int open}) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x7B) depth++;
    if (text.codeUnitAt(i) == 0x7D && --depth == 0) return i;
  }
  return -1;
}
