import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/settings/web_extension.dart';

final _ublock = WebExtensionEntry(
  id: WebExtensionId('we-ublock'),
  name: 'uBlock Origin',
  version: '1.62.0',
  permissions: const {'storage', 'nativeMessaging'},
  hosts: const {'<all_urls>'},
);
final _reader = WebExtensionEntry(
  id: WebExtensionId('we-reader'),
  name: 'Dark Reader',
  version: '4.9',
  permissions: const {'storage'},
  hosts: const {'<all_urls>'},
);

ExtensionAttachInputs _inputs({
  bool supported = true,
  bool experimentOn = true,
  bool archived = false,
  bool kiosk = false,
  bool incognito = false,
  Set<WebExtensionId>? enabled,
}) => (
  supported: supported,
  experimentOn: experimentOn,
  archived: archived,
  kiosk: kiosk,
  incognito: incognito,
  enabled: enabled ?? {_ublock.id},
  library: [_ublock, _reader],
  claims: [DomainClaim.baseDomain('example.com')],
);

String _label(ExtensionAttach attach) => switch (attach) {
  NoExtensions(:final reason) => 'none:${reason.name}',
  AttachExtensions(:final persistent, :final loads) =>
    '${persistent ? 'persistent' : 'ephemeral'}:'
        '${loads.map((l) => l.id).join(',')}',
};

/// Each row: the site and app as they stand, and what the site's webviews
/// attach.
final _rows = <(String, ExtensionAttachInputs, String)>[
  ('an ordinary site', _inputs(), 'persistent:we-ublock'),
  (
    'two switched on',
    _inputs(enabled: {_ublock.id, _reader.id}),
    'persistent:we-ublock,we-reader',
  ),
  ('an incognito site', _inputs(incognito: true), 'ephemeral:we-ublock'),
  ('none switched on', _inputs(enabled: {}), 'none:noneEnabled'),
  (
    'an id no longer in the library',
    _inputs(enabled: {WebExtensionId('we-gone')}),
    'none:noneEnabled',
  ),
  ('an older system', _inputs(supported: false), 'none:unsupported'),
  ('the experiment off', _inputs(experimentOn: false), 'none:experimentOff'),
  ('an archived site', _inputs(archived: true), 'none:archive'),
  ('a kiosk site', _inputs(kiosk: true), 'none:kiosk'),
  (
    'an archived incognito site',
    _inputs(archived: true, incognito: true),
    'none:archive',
  ),
  (
    'unsupported wins over the switch',
    _inputs(supported: false, experimentOn: false),
    'none:unsupported',
  ),
];

List<String> _misses(ExtensionAttach Function(ExtensionAttachInputs) plan) => [
  for (final (label, inputs, want) in _rows)
    if (_label(plan(inputs)) != want) label,
];

/// Planted mistake: the archive tier not consulted.
ExtensionAttach _archiveIgnored(ExtensionAttachInputs i) =>
    planExtensionAttach((
      supported: i.supported,
      experimentOn: i.experimentOn,
      archived: false,
      kiosk: i.kiosk,
      incognito: i.incognito,
      enabled: i.enabled,
      library: i.library,
      claims: i.claims,
    ));

/// Planted mistake: an incognito site given a persistent controller.
ExtensionAttach _incognitoPersistent(ExtensionAttachInputs i) =>
    switch (planExtensionAttach(i)) {
      AttachExtensions(:final loads) => AttachExtensions(
        persistent: true,
        loads: loads,
      ),
      final none => none,
    };

/// Planted mistake: every library entry loaded, switched on or not.
ExtensionAttach _ignoresEnabled(ExtensionAttachInputs i) =>
    planExtensionAttach((
      supported: i.supported,
      experimentOn: i.experimentOn,
      archived: i.archived,
      kiosk: i.kiosk,
      incognito: i.incognito,
      enabled: {for (final e in i.library) e.id},
      library: i.library,
      claims: i.claims,
    ));

void main() {
  group('WEBEXT-016 a site attaches what it switched on, where it may', () {
    test('every row attaches what the site and app call for', () {
      expect(_misses(planExtensionAttach), isEmpty);
    });

    test('each extension is granted the site only', () {
      final attach = planExtensionAttach(_inputs()) as AttachExtensions;
      expect(attach.loads.single.grants.matchPatterns, {'*://*.example.com/*'});
      expect(attach.loads.single.grants.permissions, {'storage'});
    });
  });

  group('WEBEXT-016 planted mistakes are caught', () {
    test('the archive tier ignored misses a row', () {
      expect(_misses(_archiveIgnored), isNotEmpty);
    });

    test('an incognito site kept persistent misses a row', () {
      expect(_misses(_incognitoPersistent), isNotEmpty);
    });

    test('extensions loaded whether switched on or not misses a row', () {
      expect(_misses(_ignoresEnabled), isNotEmpty);
    });
  });
}
