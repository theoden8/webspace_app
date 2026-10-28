import 'dart:convert';

/// [value] as `jsonDecode` hands a reply over, so a test reads the types a
/// real body decodes to.
Object? _decoded(Object? value) => jsonDecode(jsonEncode(value));

/// An addons.mozilla.org API v5 addon detail reply, shaped like AdNauseam's
/// listing.
Object? amoAddonReply({
  String version = '3.24.2',
  String type = 'extension',
  String fileUrl =
      'https://addons.mozilla.org/firefox/downloads/file/4398765/adnauseam-3.24.2.xpi',
  Object? size = 3895342,
  bool withCurrentVersion = true,
}) => _decoded({
  'id': 607454,
  'authors': [
    {
      'id': 12929064,
      'name': 'Daniel C. Howe',
      'url': 'https://addons.mozilla.org/en-US/firefox/user/12929064/',
      'username': 'dhowe',
      'picture_url': null,
    },
  ],
  'average_daily_users': 64210,
  'categories': ['privacy-security'],
  'contributions_url': null,
  'created': '2016-05-09T21:52:40Z',
  if (withCurrentVersion)
    'current_version': {
      'id': 5843214,
      'compatibility': {
        'firefox': {'min': '115.0', 'max': '*'},
        'android': {'min': '120.0', 'max': '*'},
      },
      'edit_url':
          'https://addons.mozilla.org/en-US/developers/addon/adnauseam/versions/5843214',
      'file': {
        'id': 4398765,
        'created': '2025-02-11T09:14:03Z',
        'hash':
            'sha256:5f1d0c8e2a7b9d4c3e6f8a1b2c3d4e5f60718293a4b5c6d7e8f9012345678abc',
        'is_mozilla_signed_extension': false,
        'optional_permissions': <String>[],
        'host_permissions': <String>[],
        'permissions': [
          'privacy',
          'dns',
          'menus',
          'alarms',
          'storage',
          'tabs',
          'unlimitedStorage',
          'webNavigation',
          'webRequest',
          'webRequestBlocking',
          '<all_urls>',
        ],
        'size': size,
        'status': 'public',
        'url': fileUrl,
      },
      'is_strict_compatibility_enabled': false,
      'license': {
        'id': 6,
        'is_custom': false,
        'name': {'en-US': 'GNU General Public License v3.0'},
        'url': 'https://www.gnu.org/licenses/gpl-3.0.html',
      },
      'release_notes': {'en-US': 'Fixes for the latest uBlock Origin merge.'},
      'reviewed': null,
      'version': version,
    },
  'default_locale': 'en-US',
  'description': {
    'en-US':
        'AdNauseam quietly clicks on every blocked ad, registering a '
        'visit on ad networks\' databases.',
  },
  'guid': 'adnauseam@rednoise.org',
  'has_eula': false,
  'has_privacy_policy': false,
  'homepage': {
    'url': {'en-US': 'https://adnauseam.io'},
  },
  'icon_url':
      'https://addons.mozilla.org/user-media/addon_icons/607/607454-64.png',
  'is_disabled': false,
  'is_experimental': false,
  'last_updated': '2025-02-11T10:02:41Z',
  'name': {'en-US': 'AdNauseam'},
  'previews': <Object?>[],
  'promoted': <Object?>[],
  'ratings': {
    'average': 4.4,
    'bayesian_average': 4.39,
    'count': 512,
    'text_count': 220,
  },
  'requires_payment': false,
  'slug': 'adnauseam',
  'status': 'public',
  'summary': {'en-US': 'Fight back against advertising surveillance.'},
  'tags': <String>[],
  'type': type,
  'url': 'https://addons.mozilla.org/en-US/firefox/addon/adnauseam/',
  'weekly_downloads': 3120,
});

Map<String, Object?> _asset({
  required String owner,
  required String repo,
  required String tag,
  required String name,
  required int id,
  required int size,
  String contentType = 'application/octet-stream',
}) => {
  'url': 'https://api.github.com/repos/$owner/$repo/releases/assets/$id',
  'id': id,
  'node_id': 'RA_kwDOAbCdEs4K$id',
  'name': name,
  'label': '',
  'uploader': {'login': owner, 'id': 1049872, 'type': 'User'},
  'content_type': contentType,
  'state': 'uploaded',
  'size': size,
  'download_count': 1832,
  'created_at': '2025-03-04T18:21:07Z',
  'updated_at': '2025-03-04T18:21:09Z',
  'browser_download_url':
      'https://github.com/$owner/$repo/releases/download/$tag/$name',
};

Map<String, Object?> _release({
  required String owner,
  required String repo,
  required Object? tag,
  required List<Map<String, Object?>> assets,
}) => {
  'url': 'https://api.github.com/repos/$owner/$repo/releases/201234567',
  'assets_url':
      'https://api.github.com/repos/$owner/$repo/releases/201234567/assets',
  'html_url': 'https://github.com/$owner/$repo/releases/tag/$tag',
  'id': 201234567,
  'author': {'login': owner, 'id': 1049872, 'type': 'User'},
  'node_id': 'RE_kwDOAbCdEs4MAbCd',
  'tag_name': tag,
  'target_commitish': 'main',
  'name': '$repo $tag',
  'draft': false,
  'prerelease': false,
  'created_at': '2025-03-04T18:02:11Z',
  'published_at': '2025-03-04T18:21:30Z',
  'assets': assets,
  'tarball_url': 'https://api.github.com/repos/$owner/$repo/tarball/$tag',
  'zipball_url': 'https://api.github.com/repos/$owner/$repo/zipball/$tag',
  'body': 'Release notes.',
};

/// A GitHub latest-release reply for `example-dev/ext` at [tag]: a Firefox
/// package, a Chrome package, a source archive and a checksum list, in the
/// order GitHub lists them.
Object? extReleaseReply({String tag = 'v2.1.0'}) {
  final version = tag.replaceFirst(RegExp('^v'), '');
  Map<String, Object?> asset(String name, {required int id, int size = 1}) =>
      _asset(
        owner: 'example-dev',
        repo: 'ext',
        tag: tag,
        name: name,
        id: id,
        size: size,
      );
  return _decoded(
    _release(
      owner: 'example-dev',
      repo: 'ext',
      tag: tag,
      assets: [
        asset('ext-$version.xpi', id: 101, size: 412233),
        asset('ext-$version.crx', id: 102, size: 405118),
        asset('ext-$version-source.zip', id: 103, size: 980552),
        asset('checksums.txt', id: 104, size: 287),
      ],
    ),
  );
}

/// A GitHub latest-release reply shaped like AdNauseam's, a package for
/// each browser.
Object? adNauseamReleaseReply() {
  const tag = 'v3.24.2';
  Map<String, Object?> asset(String name, {required int id}) => _asset(
    owner: 'dhowe',
    repo: 'AdNauseam',
    tag: tag,
    name: name,
    id: id,
    size: 3800000 + id,
    contentType: 'application/zip',
  );
  return _decoded(
    _release(
      owner: 'dhowe',
      repo: 'AdNauseam',
      tag: tag,
      assets: [
        asset('adnauseam-3.24.2.chromium.zip', id: 201),
        asset('adnauseam-3.24.2.edge.zip', id: 202),
        asset('adnauseam-3.24.2.firefox.xpi', id: 203),
        asset('adnauseam-3.24.2.opera.crx', id: 204),
      ],
    ),
  );
}

/// A GitHub latest-release reply at [tag] whose assets are [assets], each a
/// name and its download link as the reply lists them.
Object? releaseReplyWith({
  required Object? tag,
  required List<({Object? name, Object? url})> assets,
}) => _decoded(
  _release(
    owner: 'example-dev',
    repo: 'ext',
    tag: tag,
    assets: [
      for (final (i, a) in assets.indexed)
        {
          ..._asset(
            owner: 'example-dev',
            repo: 'ext',
            tag: '$tag',
            name: 'placeholder',
            id: 300 + i,
            size: 1024,
          ),
          'name': a.name,
          'browser_download_url': a.url,
        },
    ],
  ),
);
