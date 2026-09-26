// Structural gate on the unread badges' call-site wiring. The service and the
// widgets are unit-tested in test/site_unread_service_test.dart; what is
// checked here is where they are called from, which no unit test sees.
//
// Spec: openspec/changes/site-unread-badges/specs/site-unread-badges/spec.md

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8')
  .split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');

const MAIN = read('lib/main.dart');
const WEBVIEW = read('lib/services/webview.dart');
const SERVICE = read('lib/services/site_unread_service.dart');

const count = (text, needle) => text.split(needle).length - 1;

test('UNREAD-001: a post is counted only after the frame check', () => {
  const at = WEBVIEW.indexOf("handlerName: 'webNotification'");
  assert.notEqual(at, -1, 'webNotification registration is gone');
  const body = WEBVIEW.slice(at, WEBVIEW.indexOf('addJavaScriptHandler', at + 1));
  const frameCheck = body.indexOf('if (!call.isMainFrame)');
  const record = body.indexOf('SiteUnreadService.instance.recordNotification(siteId');
  assert.notEqual(record, -1, 'the handler no longer records the post');
  assert.ok(frameCheck !== -1 && frameCheck < record,
    'a cross-origin frame must be dropped before it can badge the site');
});

test('UNREAD-001: switching to a site and resuming on it mark it seen', () => {
  const setIndex = blockAfter(MAIN, 'Future<void> _setCurrentIndex(int? index) async', null, 'main.dart');
  assert.match(setIndex,
    /_currentIndex = index;\s*SiteUnreadService\.instance\.markSeen\(_webViewModels\[index\]\.siteId\);/,
    'the site becomes current and is marked seen in the same step');
  const lifecycle = blockAfter(MAIN, 'void didChangeAppLifecycleState(AppLifecycleState state)', null, 'main.dart');
  const resumed = lifecycle.slice(lifecycle.indexOf('state == AppLifecycleState.resumed'));
  assert.ok(resumed.includes('SiteUnreadService.instance.markSeen('),
    'returning to the app marks the site on screen seen');
  assert.ok(MAIN.includes('SiteUnreadService.instance.isOnScreen = _isSiteOnScreen;'),
    'the service must know which site is on screen');
});

test('UNREAD-002: both drawer layouts, the tab strip and the menu button show it', () => {
  const tile = blockAfter(MAIN, 'Widget _buildSiteGridTileContent(', ') {', 'main.dart');
  assert.equal(count(tile, 'SiteUnreadBadge('), 2, 'wide and narrow tile layouts');
  const tab = blockAfter(MAIN, 'Widget _buildTabStripItemContent(', ') {', 'main.dart');
  assert.equal(count(tab, 'SiteUnreadBadge('), 1, 'tab strip item');
  const appBar = blockAfter(MAIN, 'AppBar _buildAppBar()', null, 'main.dart');
  assert.ok(appBar.includes('UnreadMenuIcon('), 'menu button indicator');
});

test('UNREAD-003: nothing is persisted and removed sites are forgotten', () => {
  const imports = SERVICE.split('\n').filter((l) => l.startsWith('import '));
  assert.deepEqual(imports, [
    "import 'package:flutter/foundation.dart';",
  ], 'the service must stay in memory: no storage, log or platform import');
  assert.equal(count(MAIN, 'SiteUnreadService.instance.retainOnly(activeSiteIds);'), 2,
    'site deletion and settings import');
  assert.ok(/for \(final sid in slice\.siteIds\) \{\s*SiteUnreadService\.instance\.forget\(sid\);/.test(MAIN),
    'closing an archive forgets its sites');
});
