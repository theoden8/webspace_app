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
  everySite: false,
);
final _reader = WebExtensionEntry(
  id: WebExtensionId('we-reader'),
  name: 'Dark Reader',
  version: '4.9',
  permissions: const {'storage'},
  hosts: const {'<all_urls>'},
  everySite: false,
);

ExtensionAttachInputs _inputs({
  bool offered = true,
  bool archived = false,
  bool kiosk = false,
  bool incognito = false,
  Map<WebExtensionId, bool>? choices,
  bool readerEverySite = false,
}) => (
  offered: offered,
  archived: archived,
  kiosk: kiosk,
  incognito: incognito,
  choices: choices ?? {_ublock.id: true},
  library: [
    (entry: _ublock, folder: '/lib/we-ublock'),
    (
      entry: _reader.withEverySite(on: readerEverySite),
      folder: '/lib/we-reader',
    ),
  ],
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
    _inputs(choices: {_ublock.id: true, _reader.id: true}),
    'persistent:we-ublock,we-reader',
  ),
  ('an incognito site', _inputs(incognito: true), 'ephemeral:we-ublock'),
  ('none switched on', _inputs(choices: {}), 'none:noneEnabled'),
  (
    'an id no longer in the library',
    _inputs(choices: {WebExtensionId('we-gone'): true}),
    'none:noneEnabled',
  ),
  ('not offered here', _inputs(offered: false), 'none:notOffered'),
  ('an archived site', _inputs(archived: true), 'none:archive'),
  ('a kiosk site', _inputs(kiosk: true), 'none:kiosk'),
  (
    'an archived incognito site',
    _inputs(archived: true, incognito: true),
    'none:archive',
  ),
  (
    'not offered wins over the archive',
    _inputs(offered: false, archived: true),
    'none:notOffered',
  ),
];

List<String> _misses(ExtensionAttach Function(ExtensionAttachInputs) plan) => [
  for (final (label, inputs, want) in _rows)
    if (_label(plan(inputs)) != want) label,
];

/// Planted mistake: the archive tier not consulted.
ExtensionAttach _archiveIgnored(ExtensionAttachInputs i) =>
    planExtensionAttach((
      offered: i.offered,
      archived: false,
      kiosk: i.kiosk,
      incognito: i.incognito,
      choices: i.choices,
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
      offered: i.offered,
      archived: i.archived,
      kiosk: i.kiosk,
      incognito: i.incognito,
      choices: {for (final e in i.library) e.entry.id: true},
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

    test('each extension loads from its own folder', () {
      final attach =
          planExtensionAttach(
                _inputs(choices: {_ublock.id: true, _reader.id: true}),
              )
              as AttachExtensions;
      expect([for (final l in attach.loads) l.folder], [
        '/lib/we-ublock',
        '/lib/we-reader',
      ]);
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

  group('WEBEXT-004 a site follows each extension\'s default until it sets its '
      'own', () {
    /// Each row: the site's own choices and Dark Reader's default, and what
    /// the site's webviews attach.
    final rows = <(String, ExtensionAttachInputs, String)>[
      (
        'on for every site, followed',
        _inputs(readerEverySite: true),
        'persistent:we-ublock,we-reader',
      ),
      (
        'on for every site, off for this one',
        _inputs(
          readerEverySite: true,
          choices: {_ublock.id: true, _reader.id: false},
        ),
        'persistent:we-ublock',
      ),
      (
        'off for every site, on for this one',
        _inputs(choices: {_ublock.id: true, _reader.id: true}),
        'persistent:we-ublock,we-reader',
      ),
      (
        'on for every site, on a kiosk',
        _inputs(readerEverySite: true, kiosk: true),
        'none:kiosk',
      ),
      ('nothing chosen, nothing on', _inputs(choices: {}), 'none:noneEnabled'),
    ];
    List<String> misses(ExtensionAttach Function(ExtensionAttachInputs) plan) =>
        [
          for (final (label, inputs, want) in rows)
            if (_label(plan(inputs)) != want) label,
        ];

    test('every row attaches what the choices and defaults call for', () {
      expect(misses(planExtensionAttach), isEmpty);
    });

    test('a default the planner ignores misses a row', () {
      ExtensionAttach ignoresDefault(ExtensionAttachInputs i) =>
          planExtensionAttach((
            offered: i.offered,
            archived: i.archived,
            kiosk: i.kiosk,
            incognito: i.incognito,
            choices: i.choices,
            library: [
              for (final (:entry, :folder) in i.library)
                (entry: entry.withEverySite(on: false), folder: folder),
            ],
            claims: i.claims,
          ));
      expect(misses(ignoresDefault), contains('on for every site, followed'));
    });

    test('a default that wins over the site\'s own choice misses a row', () {
      ExtensionAttach defaultWins(ExtensionAttachInputs i) =>
          planExtensionAttach((
            offered: i.offered,
            archived: i.archived,
            kiosk: i.kiosk,
            incognito: i.incognito,
            choices: {
              for (final (:entry, folder: _) in i.library)
                if (entry.everySite || (i.choices[entry.id] ?? false))
                  entry.id: true,
            },
            library: i.library,
            claims: i.claims,
          ));
      expect(
        misses(defaultWins),
        contains('on for every site, off for this one'),
      );
    });
  });
}
