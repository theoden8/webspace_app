import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/page_js.dart';

final _include = RegExp(r'^[ \t]*// @include (\S+)', multiLine: true);

void main() {
  test('every lib/js file is a script or a part a script includes', () {
    final files = {
      for (final f in Directory(PageJs.dir).listSync().whereType<File>())
        f.uri.pathSegments.last,
    };
    final parts = files.where((f) => f.startsWith('_')).toSet();
    expect(files.difference(parts), {for (final js in PageJs.values) '${js.file}.js'},
        reason: 'a file with no PageJs value is never injected');
    final included = {
      for (final js in PageJs.values)
        for (final m in _include
            .allMatches(File('${PageJs.dir}/${js.file}.js').readAsStringSync()))
          m[1]!,
    };
    expect(included, parts, reason: 'a part no script includes is dead code');
  });

  test('a part is resolved in place', () {
    final js = PageJs.screenShare.withConfig({
      'shimGroup': 'screen_share',
      'deviceLabel': 'Screen',
      'requestHandler': 'webScreenShareRequest',
    });
    expect(js, isNot(contains('// @include')));
    expect(js, contains('__wsStopRealCapture'));
  });

  test('a value reaches a script only as a JSON literal', () {
    // Quote, statement break, backslash, CRLF and a </script>: raw, any of
    // them would end the literal and run what follows in the page.
    const payload = 'x"; window.__ws_pwned = 1; var y = "\\\r\n</script>  ';
    final js = PageJs.language.withConfig({'language': payload});
    expect(js, contains(jsonEncode(payload)));
    expect(js.replaceAll(jsonEncode(payload), ''), isNot(contains('__ws_pwned')));
  });

  test('withConfig takes exactly the keys the script reads', () {
    expect(() => PageJs.language.withConfig({}), throwsA(isA<AssertionError>()));
    expect(() => PageJs.language.withConfig({'language': 'en', 'extra': 1}),
        throwsA(isA<AssertionError>()));
  });

  test('a script that reads CONFIG cannot be injected without one', () {
    expect(() => PageJs.language.script, throwsA(isA<AssertionError>()));
    expect(PageJs.doNotTrack.script, isNot(contains('CONFIG')));
  });
}
