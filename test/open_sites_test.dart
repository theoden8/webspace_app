// Which sites show their tabs in the site strip and the sidebar's squares:
// the site on screen until it is shut, any other once opened; on a phone one
// at a time.

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/open_sites.dart';
import 'package:webspace/settings/site_ids.dart';

void main() {
  final docs = SiteId('docs');
  final mail = SiteId('mail');
  final chat = SiteId('chat');

  List<SiteId> open(OpenSites sites, {required SiteId current}) => [
        for (final id in [docs, mail, chat])
          if (sites.isOpen(id, current: current)) id,
      ];

  test('the site on screen shows its tabs, the others do not', () {
    expect(open(const OpenSites(), current: docs), [docs]);
  });

  test('a second tap on the site on screen closes them', () {
    final sites = const OpenSites().toggle(docs, current: docs, single: false);
    expect(open(sites, current: docs), isEmpty);
    expect(open(sites.toggle(docs, current: docs, single: false), current: docs),
        [docs]);
  });

  test('a wide window keeps several open', () {
    final sites = const OpenSites()
        .toggle(mail, current: docs, single: false)
        .toggle(chat, current: docs, single: false);
    expect(open(sites, current: docs), [docs, mail, chat]);
  });

  test('a phone keeps one open, the site on screen included', () {
    var sites = const OpenSites().toggle(mail, current: docs, single: true);
    expect(open(sites, current: docs), [mail]);
    sites = sites.toggle(chat, current: docs, single: true);
    expect(open(sites, current: docs), [chat]);
    sites = sites.toggle(docs, current: docs, single: true);
    expect(open(sites, current: docs), [docs]);
  });

  test('switching site opens the new one; a phone closes the rest', () {
    final wide = const OpenSites()
        .toggle(chat, current: docs, single: false)
        .toggle(mail, current: docs, single: false)
        .toggle(mail, current: docs, single: false);
    expect(open(wide.onSwitch(to: mail, single: false), current: mail),
        [mail, chat]);
    final phone = const OpenSites().toggle(chat, current: docs, single: true);
    expect(open(phone.onSwitch(to: mail, single: true), current: mail), [mail]);
  });
}
