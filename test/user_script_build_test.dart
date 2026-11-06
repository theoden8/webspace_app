// Coverage for UserScriptService.sourcesAt() and the once-per-document guard:
// which scripts reach the webview at each injection time, in what order, and
// wrapped in which guard. Their group and timing are ShimGroup's
// (test/page_shim_test.dart). Controller-free (no webview needed).

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/user_script.dart';

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
      final userScripts =
          svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd);
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
        scripts: [UserScriptConfig(id: UserScriptId('a-b.c'), name: 't', source: 'X();')],
        proxy: OutboundProxy.app,
      );
      final user = svc.sourcesAt(UserScriptInjectionTime.atDocumentEnd).single;
      expect(user, contains('window.__wsRan_a_b_c'));
    });
  });
}
