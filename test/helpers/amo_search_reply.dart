/// One page of an addons.mozilla.org API v5 search as the server sent it on
/// 2026-10-28, for `q=adblock&type=extension&app=firefox&sort=users&page=1`
/// `&page_size=20&lang=en-US`: four of its twenty results, the fields around
/// the ones read, and the longer host pattern lists cut to a few entries.
library;

const Map<String, Object?> amoSearchReply = {
  'page_size': 20,
  'page_count': 114,
  'count': 2271,
  'next':
      'https://addons.mozilla.org/api/v5/addons/search/?app=firefox&lang=en-US&page=2&page_size=20&q=adblock&sort=users&type=extension',
  'previous': null,
  'results': [
    {
      'id': 607454,
      'average_daily_users': 11346172,
      'categories': ['privacy-security'],
      'current_version': {
        'id': 6490666,
        'file': {
          'id': 5034826,
          'host_permissions': <Object?>[],
          'optional_permissions': <Object?>[],
          'permissions': [
            'alarms',
            'dns',
            'menus',
            'privacy',
            'storage',
            'tabs',
            'unlimitedStorage',
            'webNavigation',
            'webRequest',
            'webRequestBlocking',
            '<all_urls>',
            'http://*/*',
            'https://*/*',
            'file://*/*',
            'https://easylist.to/*',
            'https://*.reddit.com/r/uBlockOrigin/*',
          ],
          'size': 4650100,
          'status': 'public',
          'url':
              'https://addons.mozilla.org/firefox/downloads/file/5034826/ublock_origin-1.75.0.xpi',
        },
        'version': '1.75.0',
      },
      'default_locale': 'en-US',
      'guid': 'uBlock0@raymondhill.net',
      'icon_url':
          'https://addons.mozilla.org/user-media/addon_icons/607/607454-64.png?modified=mcrushed',
      'last_updated': '2026-10-28T16:12:07Z',
      'name': {'en-US': 'uBlock Origin'},
      'promoted': [
        {
          'category': 'recommended',
          'apps': ['firefox', 'android'],
        },
      ],
      'ratings': {'average': 4.8022, 'count': 22255},
      'slug': 'ublock-origin',
      'summary': {
        'en-US':
            'Finally, an efficient wide-spectrum content blocker. Easy on CPU and memory.',
      },
      'type': 'extension',
      'url': 'https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/',
      'weekly_downloads': 241205,
    },
    {
      'id': 1865,
      'average_daily_users': 2838520,
      'categories': ['privacy-security'],
      'current_version': {
        'id': 6629389,
        'file': {
          'id': 5173498,
          'host_permissions': <Object?>[],
          'optional_permissions': ['management'],
          'permissions': [
            '<all_urls>',
            'alarms',
            'contextMenus',
            'notifications',
            'storage',
            'tabs',
            'unlimitedStorage',
            'webNavigation',
            'webRequest',
            'webRequestBlocking',
            'devtools',
            'http://*/*',
            'https://*/*',
            '*://*.youtube.com/*',
            'https://adblockplus.org/*',
            '*://*.facebook.com/*',
          ],
          'size': 4105485,
          'status': 'public',
          'url':
              'https://addons.mozilla.org/firefox/downloads/file/5173498/adblock_plus-4.49.0.xpi',
        },
        'version': '4.49.0',
      },
      'default_locale': 'en-US',
      'guid': '{d10d0bf8-f5b5-c8b4-a8b2-2b9879e08c5d}',
      'icon_url':
          'https://addons.mozilla.org/user-media/addon_icons/1/1865-64.png?modified=mcrushed',
      'last_updated': '2026-10-27T14:32:07Z',
      'name': {'en-US': 'Adblock Plus'},
      'promoted': <Object?>[],
      'ratings': {'average': 4.371, 'count': 11431},
      'slug': 'adblock-plus',
      'summary': {
        'en-US':
            'One of the most popular free ad blockers for Firefox. Block annoying ads on sites like Facebook, YouTube and all other websites.\n\nAdblock Plus blocks all annoying ads, and supports websites by not blocking unobtrusive ads by default (configurable).',
      },
      'type': 'extension',
      'url': 'https://addons.mozilla.org/en-US/firefox/addon/adblock-plus/',
      'weekly_downloads': 30460,
    },
    {
      'id': 2590937,
      'average_daily_users': 815669,
      'categories': ['appearance', 'games-entertainment'],
      'current_version': {
        'id': 6353379,
        'file': {
          'id': 4897574,
          'host_permissions': <Object?>[],
          'optional_permissions': ['*://*/*'],
          'permissions': [
            'storage',
            'scripting',
            'unlimitedStorage',
            'https://sponsor.ajay.app/*',
            'https://*.youtube.com/*',
            'https://www.youtube-nocookie.com/embed/*',
          ],
          'size': 1871121,
          'status': 'public',
          'url':
              'https://addons.mozilla.org/firefox/downloads/file/4897574/sponsorblock-6.1.7.xpi',
        },
        'version': '6.1.7',
      },
      'default_locale': 'en-US',
      'guid': 'sponsorBlocker@ajay.app',
      'icon_url':
          'https://addons.mozilla.org/user-media/addon_icons/2590/2590937-64.png?modified=d215907f',
      'last_updated': '2026-07-13T16:56:51Z',
      'name': {'en-US': 'SponsorBlock - Skip Sponsorships on YouTube'},
      'promoted': [
        {
          'category': 'recommended',
          'apps': ['firefox', 'android'],
        },
      ],
      'ratings': {'average': 4.8109, 'count': 3242},
      'slug': 'sponsorblock',
      'summary': {
        'en-US':
            'Easily skip YouTube video sponsors. When you visit a YouTube video, the extension will check the database for reported sponsors and automatically skip known sponsors. You can also report sponsors in videos. Other browsers: https://sponsor.ajay.app',
      },
      'type': 'extension',
      'url': 'https://addons.mozilla.org/en-US/firefox/addon/sponsorblock/',
      'weekly_downloads': 13425,
    },
    {
      'id': 544242,
      'average_daily_users': 63704,
      'categories': ['privacy-security', 'search-tools'],
      'current_version': {
        'id': 5830680,
        'file': {
          'id': 4374970,
          'host_permissions': ['https://www.qwant.com/'],
          'optional_permissions': <Object?>[],
          'permissions': [
            'declarativeNetRequest',
            'webNavigation',
            'storage',
            'tabs',
            'cookies',
            'https://*.qwant.com/*',
          ],
          'size': 369150,
          'status': 'public',
          'url':
              'https://addons.mozilla.org/firefox/downloads/file/4374970/qwantcom_for_firefox-8.1.0.xpi',
        },
        'version': '8.1.0',
      },
      'default_locale': 'en-US',
      'guid': 'qwantcomforfirefox@jetpack',
      'icon_url':
          'https://addons.mozilla.org/user-media/addon_icons/544/544242-64.png?modified=e8625cf9',
      'last_updated': '2024-10-31T14:46:18Z',
      'name': {'en-US': 'Qwant - Search engine & tracker blocker'},
      'promoted': <Object?>[],
      'ratings': {'average': 4.2868, 'count': 645},
      'slug': 'qwantcom-for-firefox',
      'summary': {
        'en-US':
            'The Qwant extension sets qwant.com as your default search engine and blocks trackers.',
      },
      'type': 'extension',
      'url':
          'https://addons.mozilla.org/en-US/firefox/addon/qwantcom-for-firefox/',
      'weekly_downloads': 86,
    },
  ],
};
