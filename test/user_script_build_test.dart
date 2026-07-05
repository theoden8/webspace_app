// Coverage for UserScriptService.buildInitialUserScripts() and the
// once-per-document guard — the injection-list assembly that decides which
// scripts reach the webview, in what order, at which injection time, and
// wrapped in which guard. Controller-free (no webview needed).

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/user_script.dart';

void main() {
  group('buildInitialUserScripts', () {
    test('no enabled scripts produces an empty list and no shim', () {
      final svc = UserScriptService(scripts: [
        UserScriptConfig(name: 'off', source: 'noop;', enabled: false),
      ]);
      expect(svc.hasScripts, isFalse);
      expect(svc.buildInitialUserScripts(), isEmpty);
    });

    test('shim is injected first at DOCUMENT_START, then the guarded script', () {
      final svc = UserScriptService(scripts: [
        UserScriptConfig(
          id: 'abc',
          name: 't',
          source: 'MARK_A();',
          injectionTime: UserScriptInjectionTime.atDocumentStart,
        ),
      ]);
      final scripts = svc.buildInitialUserScripts();
      expect(scripts.length, 2);

      expect(scripts[0].groupName, 'script_fetch_shim');
      expect(scripts[0].injectionTime,
          inapp.UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(scripts[0].source, contains('Node.prototype.appendChild'));

      expect(scripts[1].groupName, 'user_scripts');
      expect(scripts[1].injectionTime,
          inapp.UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(scripts[1].source, contains('MARK_A();'));
      expect(scripts[1].source, contains('window.__wsRan_abc'));
    });

    test('disabled and empty-source scripts are skipped', () {
      final svc = UserScriptService(scripts: [
        UserScriptConfig(name: 'a', source: 'KEEP_A();'),
        UserScriptConfig(name: 'b', source: 'DROP_B();', enabled: false),
        UserScriptConfig(name: 'c', source: ''),
      ]);
      final userScripts = svc
          .buildInitialUserScripts()
          .where((s) => s.groupName == 'user_scripts')
          .toList();
      expect(userScripts.length, 1);
      expect(userScripts.single.source, contains('KEEP_A();'));
      expect(userScripts.single.source, isNot(contains('DROP_B();')));
    });

    test('atDocumentEnd script maps to DOCUMENT_END injection time', () {
      final svc = UserScriptService(scripts: [
        UserScriptConfig(
          name: 't',
          source: 'END();',
          injectionTime: UserScriptInjectionTime.atDocumentEnd,
        ),
      ]);
      final user = svc
          .buildInitialUserScripts()
          .firstWhere((s) => s.groupName == 'user_scripts');
      expect(user.injectionTime, inapp.UserScriptInjectionTime.AT_DOCUMENT_END);
    });

    test('urlSource library is concatenated before the user source', () {
      final svc = UserScriptService(scripts: [
        UserScriptConfig(
          name: 't',
          source: 'INIT();',
          urlSource: 'LIB();',
        ),
      ]);
      final user = svc
          .buildInitialUserScripts()
          .firstWhere((s) => s.groupName == 'user_scripts');
      final libAt = user.source.indexOf('LIB();');
      final initAt = user.source.indexOf('INIT();');
      expect(libAt, greaterThanOrEqualTo(0));
      expect(initAt, greaterThan(libAt));
    });

    test('guard sanitizes non-alphanumeric characters in the script id', () {
      final svc = UserScriptService(scripts: [
        UserScriptConfig(id: 'a-b.c', name: 't', source: 'X();'),
      ]);
      final user = svc
          .buildInitialUserScripts()
          .firstWhere((s) => s.groupName == 'user_scripts');
      expect(user.source, contains('window.__wsRan_a_b_c'));
    });
  });
}
