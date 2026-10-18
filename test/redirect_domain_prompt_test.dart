import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/widgets/site_editing_prompts.dart';

import 'helpers/localized.dart';

void main() {
  for (final (button, expected) in [('Add', true), ('Cancel', false)]) {
    testWidgets('$button answers the domain suggestion', (tester) async {
      final result = Completer<bool>();
      await pumpLocalized(
        tester,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.complete(
                  await DialogSiteEditingPrompts(
                    context,
                    shell: ShellStore(SiteRuntime()),
                  ).addRedirectDomain(
                    DomainClaim.baseDomain('theguardian.com'),
                  ),
                );
              },
              child: const Text('Open suggestion'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open suggestion'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This site redirected to theguardian.com. Add this domain so future links open here?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(await result.future, expected);
    });
  }
}
