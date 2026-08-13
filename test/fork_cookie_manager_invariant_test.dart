// Structural gate on the pinned fork's MyCookieManager (BUG-007 attempt 4,
// issues #524 / #525).
//
// The fork memoizes the Android CookieManager in a `public static` field with a
// null-only lazy check, so the first value written is sticky until process
// death. The container patch added two webViewId-scoped entry points, and when
// those assigned their profile-scoped manager into that static, every unscoped
// op in the class (setCookie, deleteCookies, deleteAllCookies,
// removeSessionCookies, flush, getAllCookies) silently addressed some site's
// container instead of the default jar. deleteAllCookies then wiped a live
// session and flushed the wipe to disk.
//
// The fork's own guard is a comment on the field. A JVM test would live in the
// fork's tree, but the fork is consumed here at a mutable git ref, so this repo
// can read what it actually resolved and assert the invariant holds in the
// source it is about to compile. That is the part this repo can own: CONT-008
// keeps the app from issuing the unscoped op, and this keeps a fork bump from
// silently reintroducing the mislabel underneath it.
//
// A failure here is not necessarily a regression. If the fork restructured the
// file, re-audit the new shape against the invariant, then update the anchors
// below.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _forkPackage = 'flutter_inappwebview_android';
const _sourcePath =
    'android/src/main/java/com/pichillilorenzo/flutter_inappwebview_android/'
    'MyCookieManager.java';

/// The sticky memo. Must only ever hold the default profile's manager.
const _memoField = 'cookieManager';

/// The container-scoped lookup whose result must stay in a method local.
const _scopedLookup = 'cookieManagerForContainerOf';

/// Fans the flush out across every profile's jar. PAUSE-023 depends on it:
/// without the fan-out, the on-background flush commits the default jar only
/// and every container's session cookies stay unwritten.
const _flushFanOut = 'flushContainerCookieManagers';

void main() {
  late List<String> lines;
  late List<int> depth;

  setUpAll(() {
    final source = File(_resolveForkSource());
    expect(
      source.existsSync(),
      isTrue,
      reason:
          'Cannot find $_sourcePath in the resolved $_forkPackage package. The '
          'fork moved or renamed it, so the invariant below is unverified: '
          're-audit and update the path.',
    );
    lines = _stripCommentsAndLiterals(source.readAsStringSync()).split('\n');
    depth = _braceDepthBefore(lines);
  });

  group('fork MyCookieManager static memo', () {
    test('the anchors this gate reads still exist', () {
      // Each anchor is a thing the invariant is stated in terms of. Losing one
      // silently would turn every assertion below into a vacuous pass.
      expect(
        _joined(lines),
        matches(RegExp(r'public\s+static\s+CookieManager\s+' + _memoField)),
        reason: 'the static memo is gone: re-audit, this gate assumes it exists',
      );
      expect(
        _classLevelDeclarationOf(_scopedLookup, lines, depth),
        isNotNull,
        reason: '$_scopedLookup is gone: the scoped lookup was renamed or '
            'removed, so this gate no longer covers it',
      );
      expect(
        _classLevelDeclarationOf(_flushFanOut, lines, depth),
        isNotNull,
        reason: '$_flushFanOut is gone: PAUSE-023 assumes flush reaches every '
            "container's jar",
      );
    });

    test('the scoped lookup is never assigned into the static memo', () {
      final offenders = <String>[];
      for (var i = 0; i < lines.length; i++) {
        if (RegExp('(?<![.\\w])$_memoField\\s*=\\s*$_scopedLookup\\s*\\(')
            .hasMatch(lines[i])) {
          offenders.add('MyCookieManager.java:${i + 1}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'assigning a container-scoped manager into the static memo '
            'redirects every unscoped op in the class to that container',
      );
    });

    test('every scoped lookup call site keeps the result in a local', () {
      final callSites = _callSitesOf(_scopedLookup, lines, depth);
      expect(
        callSites,
        isNotEmpty,
        reason: 'no call sites found: the scoped entry points changed shape',
      );

      final offenders = <String>[];
      for (final i in callSites) {
        final assignsToLocal = RegExp(
          r'^\s*(?:return\s+|(?:final\s+)?CookieManager\s+\w+\s*=\s*)' +
              _scopedLookup +
              r'\s*\(',
        ).hasMatch(lines[i]);
        if (!assignsToLocal) offenders.add('MyCookieManager.java:${i + 1}');
      }
      expect(
        offenders,
        isEmpty,
        reason: 'a scoped lookup must be captured as `CookieManager <local> = '
            '$_scopedLookup(...)` or returned directly',
      );
    });

    test('scoped methods do not fall back to the static memo', () {
      // Resolving a local and then operating on the static is the same defect
      // wearing a different shape: the op still lands on the wrong jar.
      final offenders = <String>[];
      for (final i in _callSitesOf(_scopedLookup, lines, depth)) {
        final body = _enclosingMethodBody(i, lines, depth);
        for (final j in body) {
          if (RegExp('(?<![.\\w])$_memoField(?![\\w(])').hasMatch(lines[j])) {
            offenders.add('MyCookieManager.java:${j + 1}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'a webViewId-scoped method referenced the unscoped static memo',
      );
    });
  });

  group('fork flush fan-out (PAUSE-023)', () {
    test('flush reaches every container jar, not just the default one', () {
      final flushBody = _methodBodyOf('flush', lines, depth);
      expect(
        flushBody,
        isNotNull,
        reason: 'flush() is gone: the on-background durability hook has no '
            'implementation to call',
      );
      expect(
        _joined(flushBody!.map((i) => lines[i])),
        contains('$_flushFanOut()'),
        reason: 'flush() commits the default jar only, so container sessions '
            'stay unwritten when the OS kills the app',
      );

      final fanOutBody = _methodBodyOf(_flushFanOut, lines, depth)!;
      final fanOut = _joined(fanOutBody.map((i) => lines[i]));
      expect(fanOut, contains('ProfileStore'));
      expect(
        fanOut,
        contains('getAllProfileNames'),
        reason: 'the fan-out must enumerate profiles rather than flushing a '
            'fixed set',
      );
    });
  });
}

String _joined(Iterable<String> lines) => lines.join('\n');

/// Absolute path of the fork source, via the package resolution `pub get`
/// wrote. Reading it this way rather than globbing the pub cache means the
/// gate always inspects the ref this checkout actually resolved.
String _resolveForkSource() {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) {
    fail('.dart_tool/package_config.json is missing: run `flutter pub get`');
  }
  final packages =
      (jsonDecode(config.readAsStringSync())['packages'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
  final fork = packages.firstWhere(
    (p) => p['name'] == _forkPackage,
    orElse: () => fail('$_forkPackage is not in package_config.json'),
  );
  var rootUri = Uri.parse(fork['rootUri'] as String);
  if (!rootUri.hasScheme) {
    rootUri =
        Uri.file('${Directory.current.path}/.dart_tool/').resolveUri(rootUri);
  }
  // Without a trailing slash, resolve() would replace the package directory
  // instead of descending into it.
  if (!rootUri.path.endsWith('/')) {
    rootUri = rootUri.replace(path: '${rootUri.path}/');
  }
  return File.fromUri(rootUri.resolve(_sourcePath)).path;
}

/// Blanks comments and string/char literals, preserving line numbering, so the
/// regexes below cannot match prose about the invariant or a brace inside a
/// literal.
String _stripCommentsAndLiterals(String src) {
  final out = StringBuffer();
  var inLineComment = false;
  var inBlockComment = false;
  var inString = false;
  var inChar = false;

  for (var i = 0; i < src.length; i++) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inLineComment) {
      if (c == '\n') {
        inLineComment = false;
        out.write(c);
      } else {
        out.write(' ');
      }
      continue;
    }
    if (inBlockComment) {
      if (c == '*' && next == '/') {
        inBlockComment = false;
        out.write('  ');
        i++;
      } else {
        out.write(c == '\n' ? '\n' : ' ');
      }
      continue;
    }
    if (inString || inChar) {
      if (c == r'\' && next.isNotEmpty) {
        out.write('  ');
        i++;
        continue;
      }
      if ((inString && c == '"') || (inChar && c == "'")) {
        inString = false;
        inChar = false;
      }
      out.write(c == '\n' ? '\n' : ' ');
      continue;
    }
    if (c == '/' && next == '/') {
      inLineComment = true;
      out.write('  ');
      i++;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlockComment = true;
      out.write('  ');
      i++;
      continue;
    }
    if (c == '"') {
      inString = true;
      out.write(' ');
      continue;
    }
    if (c == "'") {
      inChar = true;
      out.write(' ');
      continue;
    }
    out.write(c);
  }
  return out.toString();
}

/// Brace nesting depth at the START of each line. Class members sit at depth 1,
/// so a method opener is a depth-1 line that opens a brace.
List<int> _braceDepthBefore(List<String> lines) {
  final depths = <int>[];
  var current = 0;
  for (final line in lines) {
    depths.add(current);
    current += '{'.allMatches(line).length - '}'.allMatches(line).length;
  }
  return depths;
}

int? _classLevelDeclarationOf(
    String name, List<String> lines, List<int> depth) {
  for (var i = 0; i < lines.length; i++) {
    if (depth[i] == 1 &&
        RegExp('(?<![.\\w])$name\\s*\\(').hasMatch(lines[i]) &&
        lines[i].contains('{')) {
      return i;
    }
  }
  return null;
}

/// Lines that CALL [name], excluding its declaration (which sits at depth 1).
List<int> _callSitesOf(String name, List<String> lines, List<int> depth) {
  final sites = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (depth[i] > 1 && RegExp('(?<![.\\w])$name\\s*\\(').hasMatch(lines[i])) {
      sites.add(i);
    }
  }
  return sites;
}

/// Line indices of the method body containing [line], opener through closer.
List<int> _enclosingMethodBody(int line, List<String> lines, List<int> depth) {
  var start = line;
  while (start > 0 && !(depth[start] == 1 && lines[start].contains('{'))) {
    start--;
  }
  var end = line;
  while (end < lines.length - 1 && depth[end + 1] > 1) {
    end++;
  }
  return [for (var i = start; i <= end; i++) i];
}

List<int>? _methodBodyOf(String name, List<String> lines, List<int> depth) {
  final start = _classLevelDeclarationOf(name, lines, depth);
  if (start == null) return null;
  return _enclosingMethodBody(start + 1, lines, depth);
}
