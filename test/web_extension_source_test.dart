import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/services/web_extension_source_engine.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_source.dart';

import 'helpers/extension_sources.dart';

String _sourceLabel(ExtensionSource? source) => switch (source) {
  null => 'none',
  AmoSource(:final slug) => 'amo:$slug',
  GitHubSource(:final owner, :final repo, :final asset) =>
    'github:$owner/$repo${asset == null ? '' : ' $asset'}',
};

/// Each row: a link the user pastes and the source it names.
const _linkRows = <(String, String, String)>[
  (
    'a listing with its locale',
    'https://addons.mozilla.org/en-US/firefox/addon/adnauseam/',
    'amo:adnauseam',
  ),
  (
    'a listing without its locale or trailing slash',
    'https://addons.mozilla.org/firefox/addon/adnauseam',
    'amo:adnauseam',
  ),
  (
    'a listing for Android',
    'https://addons.mozilla.org/de/android/addon/ublock-origin/',
    'amo:ublock-origin',
  ),
  (
    'a page under a listing, with a query and a fragment',
    'https://addons.mozilla.org/pt-BR/firefox/addon/adnauseam/reviews/'
        '?utm_source=share#top',
    'amo:adnauseam',
  ),
  (
    'a link pasted with spaces around it',
    '  https://addons.mozilla.org/en-US/firefox/addon/adnauseam/\n',
    'amo:adnauseam',
  ),
  (
    'a repository',
    'https://github.com/dhowe/AdNauseam',
    'github:dhowe/AdNauseam',
  ),
  (
    'a repository with a trailing slash, a query and a fragment',
    'https://github.com/dhowe/AdNauseam/?tab=readme-ov-file#install',
    'github:dhowe/AdNauseam',
  ),
  (
    'its releases',
    'https://github.com/dhowe/AdNauseam/releases',
    'github:dhowe/AdNauseam',
  ),
  (
    'its latest release',
    'https://github.com/dhowe/AdNauseam/releases/latest/',
    'github:dhowe/AdNauseam',
  ),
  (
    'one of its releases reads the latest',
    'https://github.com/dhowe/AdNauseam/releases/tag/v3.20.0',
    'github:dhowe/AdNauseam',
  ),
  (
    'a release whose tag has a slash',
    'https://github.com/example-dev/ext/releases/tag/release/2.1.0',
    'github:example-dev/ext',
  ),
  (
    'a repository named with dots and underscores',
    'https://github.com/example-dev/my.ext_v2',
    'github:example-dev/my.ext_v2',
  ),
  (
    'the host and scheme in capitals',
    'HTTPS://GitHub.com/dhowe/AdNauseam',
    'github:dhowe/AdNauseam',
  ),
  (
    'plain http',
    'http://addons.mozilla.org/en-US/firefox/addon/adnauseam/',
    'none',
  ),
  ('plain http to GitHub', 'http://github.com/dhowe/AdNauseam', 'none'),
  (
    'a host ending in a source host',
    'https://addons.mozilla.org.example.net/en-US/firefox/addon/adnauseam/',
    'none',
  ),
  ('another code host', 'https://gitlab.com/dhowe/AdNauseam', 'none'),
  (
    'another store',
    'https://chromewebstore.google.com/detail/adnauseam/dkoaabhijcomjinndlgbmfnmnjnmdeeb',
    'none',
  ),
  ('an owner without a repository', 'https://github.com/dhowe', 'none'),
  (
    'a listing without its addon',
    'https://addons.mozilla.org/en-US/firefox/addon/',
    'none',
  ),
  (
    'a collection',
    'https://addons.mozilla.org/en-US/firefox/collections/4757633/privacy/',
    'none',
  ),
  (
    'an app addons.mozilla.org does not list',
    'https://addons.mozilla.org/en-US/thunderbird/addon/adnauseam/',
    'none',
  ),
  (
    'a repository\'s issues',
    'https://github.com/dhowe/AdNauseam/issues',
    'none',
  ),
  (
    'a release\'s download',
    'https://github.com/dhowe/AdNauseam/releases/download/v3.24.2/adnauseam.zip',
    'none',
  ),
  ('a name with a space', 'https://github.com/dhowe/Ad%20Nauseam', 'none'),
  (
    'a slug that is a dot segment',
    'https://addons.mozilla.org/en-US/firefox/addon/%2E%2E/',
    'none',
  ),
  ('an empty segment', 'https://github.com//dhowe/AdNauseam', 'none'),
  (
    'a user name before the host',
    'https://someone@github.com/dhowe/AdNauseam',
    'none',
  ),
  ('another port', 'https://github.com:8443/dhowe/AdNauseam', 'none'),
  ('a word', 'adnauseam', 'none'),
  ('nothing', '', 'none'),
];

typedef _Parse = ExtensionSource? Function(String link);

List<String> _linkMisses(_Parse parse) => [
  for (final (label, link, want) in _linkRows)
    if (_sourceLabel(parse(link)) != want) label,
];

/// Planted mistake: the scheme not checked, so a plain http link is read.
ExtensionSource? _schemeIgnored(String link) =>
    parseExtensionSource(link.trim().replaceFirst(RegExp('^http:'), 'https:'));

final _amoSource = AmoSource(slug: SourceName('adnauseam'));
final _extSource = GitHubSource(
  owner: SourceName('example-dev'),
  repo: SourceName('ext'),
  asset: null,
);
final _adNauseamSource = GitHubSource(
  owner: SourceName('dhowe'),
  repo: SourceName('AdNauseam'),
  asset: null,
);

GitHubSource _picking(GitHubSource source, {required String asset}) =>
    GitHubSource(owner: source.owner, repo: source.repo, asset: asset);

String _releaseLabel(ReleaseRead read) => switch (read) {
  ReleaseFound(:final version, :final candidates) =>
    '$version: ${candidates.map((c) => c.name).join(', ')}',
  ReleaseRefused(:final why) => 'refused: ${why.name}',
};

/// Each row: a source, the reply to its release query, and what it reads as.
final _releaseRows = <(String, ExtensionSource, Object?, String)>[
  (
    'a listing\'s current version',
    _amoSource,
    amoAddonReply(),
    '3.24.2: adnauseam-3.24.2.xpi',
  ),
  (
    'a listing with no current version',
    _amoSource,
    amoAddonReply(withCurrentVersion: false),
    'refused: noVersion',
  ),
  (
    'a theme is not an extension',
    _amoSource,
    amoAddonReply(type: 'statictheme'),
    'refused: noPackage',
  ),
  (
    'a file served over plain http',
    _amoSource,
    amoAddonReply(
      fileUrl:
          'http://addons.mozilla.org/firefox/downloads/file/4398765/adnauseam-3.24.2.xpi',
    ),
    'refused: noPackage',
  ),
  (
    'a Chrome package first, then a ZIP, then a Firefox package',
    _extSource,
    extReleaseReply(),
    '2.1.0: ext-2.1.0.crx, ext-2.1.0-source.zip, ext-2.1.0.xpi',
  ),
  (
    'the kind of file picked before comes first',
    _picking(_extSource, asset: 'ext-*.xpi'),
    extReleaseReply(tag: 'v2.2.0'),
    '2.2.0: ext-2.2.0.xpi, ext-2.2.0.crx, ext-2.2.0-source.zip',
  ),
  (
    'a package for each browser',
    _adNauseamSource,
    adNauseamReleaseReply(),
    '3.24.2: adnauseam-3.24.2.opera.crx, adnauseam-3.24.2.chromium.zip, '
        'adnauseam-3.24.2.edge.zip, adnauseam-3.24.2.firefox.xpi',
  ),
  (
    'the browser picked before comes first',
    _picking(_adNauseamSource, asset: 'adnauseam-*.chromium.zip'),
    adNauseamReleaseReply(),
    '3.24.2: adnauseam-3.24.2.chromium.zip, adnauseam-3.24.2.opera.crx, '
        'adnauseam-3.24.2.edge.zip, adnauseam-3.24.2.firefox.xpi',
  ),
  (
    'a picked kind the release no longer has',
    _picking(_extSource, asset: 'ext-*-firefox.xpi'),
    extReleaseReply(),
    '2.1.0: ext-2.1.0.crx, ext-2.1.0-source.zip, ext-2.1.0.xpi',
  ),
  (
    'a suffix in capitals',
    _extSource,
    releaseReplyWith(
      tag: 'v1.0',
      assets: [
        (name: 'EXT.CRX', url: 'https://github.com/example-dev/ext/EXT.CRX'),
      ],
    ),
    '1.0: EXT.CRX',
  ),
  (
    'an asset that is not a package',
    _extSource,
    releaseReplyWith(
      tag: 'v1.0',
      assets: [
        (name: 'checksums.txt', url: 'https://github.com/x/checksums.txt'),
        (name: 'ext.crx.sig', url: 'https://github.com/x/ext.crx.sig'),
      ],
    ),
    'refused: noPackage',
  ),
  (
    'an asset with a wrong-typed name or link',
    _extSource,
    releaseReplyWith(
      tag: 'v1.0',
      assets: [
        (name: 7, url: 'https://github.com/x/ext.crx'),
        (name: 'ext.zip', url: null),
        (name: 'ext.xpi', url: 'https://github.com/x/ext.xpi'),
      ],
    ),
    '1.0: ext.xpi',
  ),
  (
    'an asset served from elsewhere than https',
    _extSource,
    releaseReplyWith(
      tag: 'v1.0',
      assets: [
        (name: 'ext.crx', url: 'file:///etc/ext.crx'),
        (name: 'ext.zip', url: 'http://github.com/x/ext.zip'),
      ],
    ),
    'refused: noPackage',
  ),
  (
    'a tag without a v',
    _extSource,
    extReleaseReply(tag: '2.1.0'),
    '2.1.0: ext-2.1.0.crx, ext-2.1.0-source.zip, ext-2.1.0.xpi',
  ),
  (
    'a tag that is not a version',
    _extSource,
    releaseReplyWith(
      tag: 'nightly',
      assets: [(name: 'ext.crx', url: 'https://github.com/x/ext.crx')],
    ),
    'refused: noVersion',
  ),
  (
    'a wrong-typed tag',
    _extSource,
    releaseReplyWith(
      tag: 2,
      assets: [(name: 'ext.crx', url: 'https://github.com/x/ext.crx')],
    ),
    'refused: noVersion',
  ),
  (
    'a repository with no release',
    _extSource,
    jsonDecode(
      '{"message":"Not Found",'
      '"documentation_url":"https://docs.github.com/rest/releases/releases",'
      '"status":"404"}',
    ),
    'refused: noVersion',
  ),
  ('a reply that is a list', _extSource, jsonDecode('[]'), 'refused: notJson'),
  ('a body that did not decode', _amoSource, null, 'refused: notJson'),
];

typedef _Read =
    ReleaseRead Function(ExtensionSource source, {required Object? json});

List<String> _releaseMisses(_Read read) => [
  for (final (label, source, json, want) in _releaseRows)
    if (_releaseLabel(read(source, json: json)) != want) label,
];

/// Planted mistake: the kind of file picked before forgotten.
ReleaseRead _patternIgnored(ExtensionSource source, {required Object? json}) =>
    readRelease(switch (source) {
      AmoSource() => source,
      GitHubSource(:final owner, :final repo) => GitHubSource(
        owner: owner,
        repo: repo,
        asset: null,
      ),
    }, json: json);

/// Planted mistake: packages offered by name, not by kind.
ReleaseRead _offeredByName(ExtensionSource source, {required Object? json}) =>
    switch (readRelease(source, json: json)) {
      ReleaseFound(:final version, :final candidates) => ReleaseFound(
        version: version,
        candidates: [...candidates]..sort((a, b) => a.name.compareTo(b.name)),
      ),
      final ReleaseRefused refused => refused,
    };

/// Each row: an asset's name, its release's version, and the pattern the
/// next release's file of the same kind is picked by.
const _patternRows = <(String, String, String)>[
  ('ext-2.1.0.crx', '2.1.0', 'ext-*.crx'),
  ('ext-v2.1.0.crx', '2.1.0', 'ext-*.crx'),
  ('ext-2.1.0.crx', 'v2.1.0', 'ext-*.crx'),
  ('adnauseam-3.24.2.chromium.zip', '3.24.2', 'adnauseam-*.chromium.zip'),
  (
    'uBlock0_1.62.0.firefox.signed.xpi',
    '1.62.0',
    'uBlock0_*.firefox.signed.xpi',
  ),
  ('ext-1.0-for-1.0.crx', '1.0', 'ext-*-for-*.crx'),
  ('darkreader-chrome.zip', '4.9.96', 'darkreader-chrome.zip'),
  ('ext-11.0.crx', '1.0', 'ext-11.0.crx'),
  ('ext-1.0.1.crx', '1.0', 'ext-1.0.1.crx'),
  ('ext-2.1.0.crx', '', 'ext-2.1.0.crx'),
];

typedef _Pattern = String Function(String assetName, {required String version});

List<String> _patternMisses(_Pattern pattern) => [
  for (final (name, version, want) in _patternRows)
    if (pattern(name, version: version) != want) '$name at $version',
];

/// Planted mistake: the version replaced wherever its text appears, even
/// inside a longer number.
String _versionAnywhere(String assetName, {required String version}) =>
    version.isEmpty ? assetName : assetName.replaceAll(version, '*');

/// Each row: two versions and how the first compares with the second.
const _versionRows = <(String, String, int)>[
  ('1.10', '1.9', 1),
  ('3.24.2', '3.9.10', 1),
  ('10.0', '9.9', 1),
  ('2.0', '2.0.0', 0),
  ('1.62.0', '1.62.0', 0),
  ('01.2', '1.2', 0),
  ('1.0', '1.0.1', -1),
  ('1.0b2', '1.0', -1),
  ('1.0b2', '1.0b10', -1),
  ('1.0a1', '1.0b1', -1),
  ('1.0pre1', '1.0', -1),
  ('1.0.0b1', '1.0', -1),
  ('1.99999999999999999999999', '1.2', 1),
  ('4.9.96', '4.9.96.1', -1),
];

typedef _Compare = int Function(String version, {required String to});

List<String> _versionMisses(_Compare compare) => [
  for (final (a, b, want) in _versionRows) ...[
    if (compare(a, to: b).sign != want) '$a against $b',
    if (compare(b, to: a).sign != -want) '$b against $a',
  ],
];

/// Planted mistake: versions compared as strings.
int _asStrings(String version, {required String to}) => version.compareTo(to);

/// Planted mistake: each part read as its leading number, the rest dropped.
int _numbersOnly(String version, {required String to}) =>
    compareExtensionVersions(_leadingNumbers(version), to: _leadingNumbers(to));

String _leadingNumbers(String version) => version
    .split('.')
    .map((part) => RegExp(r'^\d*').firstMatch(part)![0]!)
    .join('.');

/// Planted mistake: a version with more parts taken as newer.
int _longerIsNewer(String version, {required String to}) {
  final order = compareExtensionVersions(version, to: to);
  if (order != 0) return order;
  return version.split('.').length.compareTo(to.split('.').length);
}

ReleaseRead _releaseAt(String tag) =>
    readRelease(_extSource, json: extReleaseReply(tag: tag));

String _checkLabel(UpdateCheck check) => switch (check) {
  UpToDate() => 'up to date',
  UpdateAvailable(:final version) => 'available: $version',
  CheckFailed(:final why) => 'failed: ${why.name}',
};

/// Each row: the installed version, what the source says, and the check.
final _checkRows = <(String, String, ReleaseRead, String)>[
  ('a newer release', '1.9', _releaseAt('v1.10'), 'available: 1.10'),
  ('the same release', '2.1.0', _releaseAt('v2.1.0'), 'up to date'),
  ('an older release is no update', '1.10', _releaseAt('v1.9'), 'up to date'),
  ('a release one part longer', '2.0', _releaseAt('v2.0.0'), 'up to date'),
  ('a pre-release installed', '1.0b2', _releaseAt('v1.0'), 'available: 1.0'),
  (
    'a source that could not be read',
    '1.0',
    const ReleaseRefused(ReleaseProblem.noVersion),
    'failed: noVersion',
  ),
];

typedef _Check =
    UpdateCheck Function({
      required String installedVersion,
      required ReleaseRead release,
    });

List<String> _checkMisses(_Check check) => [
  for (final (label, installed, release, want) in _checkRows)
    if (_checkLabel(check(installedVersion: installed, release: release)) !=
        want)
      label,
];

/// Planted mistake: any other version taken as an update, older ones too.
UpdateCheck _anyOtherVersion({
  required String installedVersion,
  required ReleaseRead release,
}) => switch (release) {
  ReleaseFound(:final version) =>
    compareExtensionVersions(version, to: installedVersion) != 0
        ? UpdateAvailable(version)
        : const UpToDate(),
  ReleaseRefused(:final why) => CheckFailed(why),
};

final _installed = WebExtensionEntry(
  id: WebExtensionId('we-ext'),
  name: 'Ext',
  version: '1.9',
  permissions: const {'storage', 'tabs'},
  hosts: const {'*://*.example.com/*'},
  everySite: false,
);

ExtensionManifest _update({
  Set<String> permissions = const {'storage', 'tabs'},
  Set<String> hosts = const {'*://*.example.com/*'},
}) => ExtensionManifest(
  name: 'Ext',
  version: '1.10',
  manifestVersion: 3,
  description: null,
  permissions: permissions,
  hosts: hosts,
  optional: const {},
  background: ExtensionBackground.serviceWorker,
  hasAction: true,
  hasOptionsPage: false,
);

String _asksLabel(UpdateAsks asks) => switch (asks) {
  AsksNothingNew() => 'nothing new',
  AsksMore(:final permissions, :final hosts) =>
    'more: ${[...permissions, ...hosts].join(', ')}',
};

/// Each row: an update's manifest against [_installed], and what the user
/// is shown before it installs.
final _asksRows = <(String, ExtensionManifest, String)>[
  ('the same asks', _update(), 'nothing new'),
  (
    'adds the cookies permission',
    _update(permissions: {'storage', 'tabs', 'cookies'}),
    'more: cookies',
  ),
  (
    'swaps tabs for cookies',
    _update(permissions: {'storage', 'cookies'}),
    'more: cookies',
  ),
  ('drops a permission', _update(permissions: {'storage'}), 'nothing new'),
  (
    'adds a host',
    _update(hosts: {'*://*.example.com/*', 'https://*.example.org/*'}),
    'more: https://*.example.org/*',
  ),
  (
    'swaps a host for another',
    _update(hosts: {'https://*.example.org/*'}),
    'more: https://*.example.org/*',
  ),
  (
    'adds both',
    _update(
      permissions: {'storage', 'tabs', 'webRequest'},
      hosts: {'*://*.example.com/*', '<all_urls>'},
    ),
    'more: webRequest, <all_urls>',
  ),
];

typedef _Asks =
    UpdateAsks Function({
      required WebExtensionEntry installed,
      required ExtensionManifest update,
    });

List<String> _asksMisses(_Asks asks) => [
  for (final (label, update, want) in _asksRows)
    if (_asksLabel(asks(installed: _installed, update: update)) != want) label,
];

/// Planted mistake: an update taken to ask for more only when it asks for
/// more things than before.
UpdateAsks _countsCompared({
  required WebExtensionEntry installed,
  required ExtensionManifest update,
}) {
  final permissions = update.permissions.length > installed.permissions.length
      ? update.permissions.difference(installed.permissions)
      : <String>{};
  final hosts = update.hosts.length > installed.hosts.length
      ? update.hosts.difference(installed.hosts)
      : <String>{};
  return permissions.isEmpty && hosts.isEmpty
      ? const AsksNothingNew()
      : AsksMore(permissions: permissions, hosts: hosts);
}

final _now = DateTime.utc(2026, 10, 28, 12);

/// Each row: when the source was last read, and whether it is read now.
final _dueRows = <(String, DateTime?, bool)>[
  ('never read', null, true),
  ('read a minute ago', _now.subtract(const Duration(minutes: 1)), false),
  ('read two hours ago', _now.subtract(const Duration(hours: 2)), false),
  ('read 23 hours ago', _now.subtract(const Duration(hours: 23)), false),
  ('read a day ago', _now.subtract(const Duration(days: 1)), true),
  ('read three days ago', _now.subtract(const Duration(days: 3)), true),
  (
    'read in the future, the clock since gone back',
    _now.add(const Duration(hours: 5)),
    true,
  ),
];

typedef _Due =
    bool Function({required DateTime? lastChecked, required DateTime now});

List<String> _dueMisses(_Due due) => [
  for (final (label, lastChecked, want) in _dueRows)
    if (due(lastChecked: lastChecked, now: _now) != want) label,
];

/// Planted mistake: a check every hour.
bool _hourly({required DateTime? lastChecked, required DateTime now}) =>
    lastChecked == null ||
    now.difference(lastChecked) >= const Duration(hours: 1);

void main() {
  group('WEBEXT-017 an extension added from a link keeps its source', () {
    test('every link row names the source it should', () {
      expect(_linkMisses(parseExtensionSource), isEmpty);
    });

    test('a source is kept through its JSON, the picked asset with it', () {
      for (final source in [
        _amoSource,
        _adNauseamSource,
        _picking(_extSource, asset: 'ext-*.crx'),
      ]) {
        final kept = jsonDecode(jsonEncode(source.toJson()));
        expect(
          _sourceLabel(ExtensionSource.fromJson(kept)),
          _sourceLabel(source),
        );
      }
      expect(_extSource.toJson().containsKey('asset'), isFalse);
    });

    test('a wrong-typed source reads as absent', () {
      for (final (json, want) in <(Object?, String)>[
        (null, 'none'),
        ('amo', 'none'),
        (['amo', 'adnauseam'], 'none'),
        ({'from': 'amo'}, 'none'),
        ({'from': 'amo', 'slug': 42}, 'none'),
        ({'from': 'amo', 'slug': '..'}, 'none'),
        ({'from': 'amo', 'slug': 'a/b'}, 'none'),
        ({'from': 'gitlab', 'owner': 'a', 'repo': 'b'}, 'none'),
        ({'from': 'github', 'owner': 'a'}, 'none'),
        ({'from': 'github', 'owner': 'a', 'repo': 7}, 'none'),
        (
          {'from': 'github', 'owner': 'a', 'repo': 'b', 'asset': 7},
          'github:a/b',
        ),
        (
          {'from': 'github', 'owner': 'a', 'repo': 'b', 'asset': ''},
          'github:a/b',
        ),
      ]) {
        expect(
          _sourceLabel(ExtensionSource.fromJson(jsonDecode(jsonEncode(json)))),
          want,
          reason: '$json',
        );
      }
    });

    test('a source names its release query', () {
      expect(
        releaseQuery(_amoSource).toString(),
        'https://addons.mozilla.org/api/v5/addons/addon/adnauseam/',
      );
      expect(
        releaseQuery(_adNauseamSource).toString(),
        'https://api.github.com/repos/dhowe/AdNauseam/releases/latest',
      );
    });

    test('every release row reads as it should', () {
      expect(_releaseMisses(readRelease), isEmpty);
    });

    test('a listing\'s package carries its link, size and what it asks', () {
      final release =
          readRelease(_amoSource, json: amoAddonReply()) as ReleaseFound;
      final package = release.candidates.single;
      expect(
        package.url.toString(),
        'https://addons.mozilla.org/firefox/downloads/file/4398765/adnauseam-3.24.2.xpi',
      );
      expect(package.size, 3895342);
      expect(package.suffix, AssetSuffix.xpi);
      expect(package.permissions, contains('webRequestBlocking'));
      expect(package.permissions, contains('<all_urls>'));

      final unsized =
          readRelease(_amoSource, json: amoAddonReply(size: '3 MB'))
              as ReleaseFound;
      expect(unsized.candidates.single.size, isNull);
    });

    test('a release asset carries its link and size, and asks nothing', () {
      final release =
          readRelease(_extSource, json: extReleaseReply()) as ReleaseFound;
      final crx = release.candidates.first;
      expect(
        crx.url.toString(),
        'https://github.com/example-dev/ext/releases/download/v2.1.0/ext-2.1.0.crx',
      );
      expect(crx.size, 405118);
      expect(crx.permissions, isEmpty);
    });

    test('the release with a Chrome and a Firefox package remembers a .crx '
        'named like ext-*.crx', () {
      final release =
          readRelease(_extSource, json: extReleaseReply()) as ReleaseFound;
      final picked = release.candidates.first;
      expect(picked.suffix, AssetSuffix.crx);
      final kept = _picking(
        _extSource,
        asset: assetPattern(picked.name, version: release.version),
      );
      expect(kept.asset, 'ext-*.crx');

      final next =
          readRelease(kept, json: extReleaseReply(tag: 'v2.2.0'))
              as ReleaseFound;
      expect(next.candidates.first.name, 'ext-2.2.0.crx');
    });

    test('every asset name row makes the pattern it should', () {
      expect(_patternMisses(assetPattern), isEmpty);
    });
  });

  group('WEBEXT-018 updates are checked; one asking for more waits', () {
    test('every version row compares as it should, both ways', () {
      expect(_versionMisses(compareExtensionVersions), isEmpty);
    });

    test('every check row says what it should', () {
      expect(_checkMisses(checkUpdate), isEmpty);
    });

    test('every update row asks for what it adds, and only that', () {
      expect(_asksMisses(updateAsks), isEmpty);
    });

    test('an update asking for more names it apart', () {
      final asks = updateAsks(
        installed: _installed,
        update: _update(
          permissions: {'storage', 'cookies'},
          hosts: {'*://*.example.com/*', 'https://*.example.org/*'},
        ),
      );
      expect(asks, isA<AsksMore>());
      final more = asks as AsksMore;
      expect(more.permissions, {'cookies'});
      expect(more.hosts, {'https://*.example.org/*'});
    });

    test('a source is read at most once a day', () {
      expect(_dueMisses(checkDue), isEmpty);
    });
  });

  group('WEBEXT-017 WEBEXT-018 planted mistakes are caught', () {
    test('a link read over plain http misses a row', () {
      expect(_linkMisses(_schemeIgnored), isNotEmpty);
    });

    test('the kind of file picked before forgotten misses a row', () {
      expect(_releaseMisses(_patternIgnored), isNotEmpty);
    });

    test('packages offered by name, not by kind, misses a row', () {
      expect(_releaseMisses(_offeredByName), isNotEmpty);
    });

    test('a version replaced inside a longer number misses a row', () {
      expect(_patternMisses(_versionAnywhere), isNotEmpty);
    });

    test('versions compared as strings miss a row', () {
      expect(_versionMisses(_asStrings), isNotEmpty);
    });

    test('a pre-release suffix dropped misses a row', () {
      expect(_versionMisses(_numbersOnly), isNotEmpty);
    });

    test('a longer version taken as newer misses a row', () {
      expect(_versionMisses(_longerIsNewer), isNotEmpty);
    });

    test('an older release offered as an update misses a row', () {
      expect(_checkMisses(_anyOtherVersion), isNotEmpty);
    });

    test('asks compared by count, not by set, misses a row', () {
      expect(_asksMisses(_countsCompared), isNotEmpty);
    });

    test('a check every hour misses a row', () {
      expect(_dueMisses(_hourly), isNotEmpty);
    });
  });
}
