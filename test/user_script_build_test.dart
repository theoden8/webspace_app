// Coverage for UserScriptService.sourcesAt() and the once-per-document guard:
// which scripts reach the webview at each injection time, in what order, and
// wrapped in which guard. Their group and timing are ShimGroup's
// (test/page_shim_test.dart). Controller-free (no webview needed).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/services/userscript_header.dart';
import 'package:webspace/settings/user_script.dart';

import 'helpers/user_script_bridge_fakes.dart';

/// The config [header] gives the page gate: its patterns as the page reads
/// them, `include` null for a header naming no page.
Map<String, Object?> _gateConfig(UserscriptHeader header) => {
  'include': switch (header.include) {
    EveryPage() => null,
    NamedPages(:final patterns) => [
      for (final p in patterns) {'source': p.source, 'flags': p.flags},
    ],
  },
  'exclude': [
    for (final p in header.exclude) {'source': p.source, 'flags': p.flags},
  ],
};

/// Whether [text] runs its code behind the page gate bound to [header]'s
/// rules (US-009): the gate script itself, with the config read back out.
bool _gated(String text, {required UserscriptHeader header}) {
  const head = '{ const ok = ';
  final end = text.indexOf('; if (ok');
  if (!text.startsWith(head) || end < 0) return false;
  final gate = text.substring(head.length, end);
  final at = gate.lastIndexOf('})(');
  if (at < 0) return false;
  final Object? config = jsonDecode(gate.substring(at + 3, gate.length - 3));
  return config is Map<String, Object?> &&
      gate == PageJs.userscriptGate.withConfig(config) &&
      jsonEncode(config) == jsonEncode(_gateConfig(header));
}

String _block(List<String> lines) =>
    ['// ==UserScript==', ...lines, '// ==/UserScript=='].join('\n');

/// Each run path's text for [script], at the time its header puts it.
Future<Map<String, List<String>>> _paths(UserScriptConfig script) async {
  final svc = UserScriptService(scripts: [script], proxy: OutboundProxy.app);
  Future<List<String>> run(
    Future<void> Function(FakeUserScriptController c) f,
  ) async {
    final c = FakeUserScriptController();
    await f(c);
    return c.evaluated
        .map((e) => e.replaceFirst(RegExp(r'\n;null;$'), ''))
        .toList();
  }

  return {
    'native at start': svc.sourcesAt(UserScriptInjectionTime.atDocumentStart),
    'native at end': svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd),
    'load start': await run((c) => svc.reinjectOnLoadStart(c.page())),
    'load stop': await run((c) => svc.reinjectOnLoadStop(c.page())),
    'single-page route': await run(
      (c) => svc.reinjectOnSpaNavigation(c.page()),
    ),
  };
}

void main() {
  group('sourcesAt', () {
    test('no enabled scripts produces an empty list and no shim', () {
      final svc = UserScriptService(
        scripts: [
          UserScriptConfig(name: 'off', source: 'noop;', enabled: false),
        ],
        proxy: OutboundProxy.app,
      );
      expect(svc.hasScripts, isFalse);
      expect(svc.shimScript, isNull);
      for (final time in UserScriptInjectionTime.values) {
        expect(svc.sourcesAt(time), isEmpty);
      }
    });

    test(
      'shim is injected first at DOCUMENT_START, then the guarded script',
      () {
        final svc = UserScriptService(
          scripts: [
            UserScriptConfig(
              id: UserScriptId('abc'),
              name: 't',
              source: 'MARK_A();',
              injectionTime: UserScriptInjectionTime.atDocumentStart,
              bypassSitePolicy: true,
            ),
          ],
          proxy: OutboundProxy.app,
        );
        expect(svc.shimScript, contains('Node.prototype.appendChild'));
        expect(ShimGroup.scriptFetch.at, ShimTime.start);
        expect(
          ShimGroup.values.indexOf(ShimGroup.scriptFetch),
          lessThan(ShimGroup.values.indexOf(ShimGroup.userScriptsAtStart)),
        );
        final start = svc.sourcesAt(UserScriptInjectionTime.atDocumentStart);
        expect(start.single, contains('MARK_A();'));
        expect(start.single, contains('window.__wsRan_abc'));
        expect(svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd), isEmpty);
      },
    );

    test('a script that asked for no bridge is injected without the shim', () {
      // The script still runs; what it does not get is the page-realm bridge
      // that would take the site's CSP and same-origin policy down with it
      // (US-DR-005).
      final svc = UserScriptService(
        scripts: [
          UserScriptConfig(
            id: UserScriptId('abc'),
            name: 't',
            source: 'MARK_A();',
            injectionTime: UserScriptInjectionTime.atDocumentStart,
          ),
        ],
        proxy: OutboundProxy.app,
      );
      expect(svc.shimScript, isNull);
      expect(
        svc.sourcesAt(UserScriptInjectionTime.atDocumentStart).single,
        contains('MARK_A();'),
      );
    });

    test('disabled and empty-source scripts are skipped (US-002)', () {
      final svc = UserScriptService(
        scripts: [
          UserScriptConfig(name: 'a', source: 'KEEP_A();'),
          UserScriptConfig(name: 'b', source: 'DROP_B();', enabled: false),
          UserScriptConfig(name: 'c', source: ''),
        ],
        proxy: OutboundProxy.app,
      );
      final userScripts = svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd);
      expect(userScripts.length, 1);
      expect(userScripts.single, contains('KEEP_A();'));
      expect(userScripts.single, isNot(contains('DROP_B();')));
    });

    test('an atDocumentEnd script is installed at document end only', () {
      final svc = UserScriptService(
        scripts: [
          UserScriptConfig(
            name: 't',
            source: 'END();',
            injectionTime: UserScriptInjectionTime.atDocumentEnd,
          ),
        ],
        proxy: OutboundProxy.app,
      );
      expect(svc.sourcesAt(UserScriptInjectionTime.atDocumentStart), isEmpty);
      expect(
        svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd).single,
        contains('END();'),
      );
    });

    test('urlSource library is concatenated before the user source', () {
      final svc = UserScriptService(
        scripts: [
          UserScriptConfig(name: 't', source: 'INIT();', urlSource: 'LIB();'),
        ],
        proxy: OutboundProxy.app,
      );
      final user = svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd).single;
      final libAt = user.indexOf('LIB();');
      final initAt = user.indexOf('INIT();');
      expect(libAt, greaterThanOrEqualTo(0));
      expect(initAt, greaterThan(libAt));
    });

    test('guard sanitizes non-alphanumeric characters in the script id', () {
      final svc = UserScriptService(
        scripts: [
          UserScriptConfig(
            id: UserScriptId('a-b.c'),
            name: 't',
            source: 'X();',
          ),
        ],
        proxy: OutboundProxy.app,
      );
      final user = svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd).single;
      expect(user, contains('window.__wsRan_a_b_c'));
    });
  });

  group('the header on every run path', () {
    final header = _block([
      '// @match https://example.com/a/*',
      '// @exclude https://example.com/a/private*',
    ]);

    test(
      'US-009: each run path runs the script behind the gate with the header\'s rules',
      () async {
        final script = UserScriptConfig(
          id: UserScriptId('h1'),
          name: 'h',
          source: '$header\nMARK();',
        );
        final paths = await _paths(script);
        final parsed = parseUserscriptHeader(script.fullSource);
        for (final path in [
          'native at end',
          'load stop',
          'single-page route',
        ]) {
          expect(paths[path], hasLength(1), reason: path);
          expect(
            _gated(paths[path]!.single, header: parsed),
            isTrue,
            reason: path,
          );
          expect(paths[path]!.single, contains('MARK();'), reason: path);
        }
        expect(paths['native at start'], isEmpty);
        expect(paths['load start'], isEmpty);
      },
    );

    test(
      'US-002: a script without a header runs behind a gate that names every page',
      () async {
        final script = UserScriptConfig(
          id: UserScriptId('h2'),
          name: 'plain',
          source: 'MARK();',
          injectionTime: UserScriptInjectionTime.atDocumentStart,
        );
        final paths = await _paths(script);
        for (final path in [
          'native at start',
          'load start',
          'single-page route',
        ]) {
          expect(
            _gated(paths[path]!.single, header: noHeader),
            isTrue,
            reason: path,
          );
          expect(
            jsonEncode(_gateConfig(noHeader)),
            '{"include":null,"exclude":[]}',
          );
        }
      },
    );

    test('US-010: @run-at moves a script between start and end', () async {
      final toStart = await _paths(
        UserScriptConfig(
          id: UserScriptId('h3'),
          name: 's',
          source: '${_block(['// @run-at document-start'])}\nMARK();',
        ),
      );
      expect(toStart['native at start'], hasLength(1));
      expect(toStart['load start'], hasLength(1));
      expect(toStart['native at end'], isEmpty);
      expect(toStart['load stop'], isEmpty);

      final toEnd = await _paths(
        UserScriptConfig(
          id: UserScriptId('h4'),
          name: 'e',
          source: '${_block(['// @run-at document-idle'])}\nMARK();',
          injectionTime: UserScriptInjectionTime.atDocumentStart,
        ),
      );
      expect(toEnd['native at end'], hasLength(1));
      expect(toEnd['load stop'], hasLength(1));
      expect(toEnd['native at start'], isEmpty);
      expect(toEnd['load start'], isEmpty);

      final unknown = await _paths(
        UserScriptConfig(
          id: UserScriptId('h5'),
          name: 'u',
          source: '${_block(['// @run-at context-menu'])}\nMARK();',
          injectionTime: UserScriptInjectionTime.atDocumentStart,
        ),
      );
      expect(
        unknown['native at start'],
        hasLength(1),
        reason: 'an unknown value leaves the stored time',
      );
    });

    test(
      'US-009: a full load runs the whole source once, a route the user\'s code again',
      () async {
        final script = UserScriptConfig(
          id: UserScriptId('h6'),
          name: 'r',
          source: 'MARK();',
          url: 'https://cdn.jsdelivr.net/lib.js',
          urlSource: 'LIBRARY();',
        );
        final paths = await _paths(script);
        expect(paths['native at end']!.single, contains('LIBRARY();'));
        expect(paths['native at end']!.single, contains('window.__wsRan_h6'));
        final route = paths['single-page route']!.single;
        expect(route, contains('MARK();'));
        expect(route, isNot(contains('LIBRARY();')));
        expect(route, isNot(contains('__wsRan')));
      },
    );

    test(
      'US-009: the check catches the planted mistake: the route path built without the gate',
      () {
        final script = UserScriptConfig(
          id: UserScriptId('h7'),
          name: 'm',
          source: '$header\nMARK();',
        );
        // The single-page route as it was built before headers were read.
        final planted =
            'console.log("__ws: SPA re-inject: ${script.name}");\n${script.source}';
        expect(
          _gated(planted, header: parseUserscriptHeader(script.fullSource)),
          isFalse,
        );
      },
    );
  });
}
