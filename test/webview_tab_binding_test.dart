import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/webview_tab_binding.dart';

void main() {
  final one = TabId.mint();
  final two = TabId.mint();
  final bytes = Uint8List.fromList([1, 2, 3]);

  test('a build for the tab the bytes were read for takes them, and its '
      'controller restores them once', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture());
    final build = binding.frame(one, commit: const Commit.fixture());
    expect(build.restores, isTrue);
    expect(binding.built, one);
    expect(binding.queued, isNull);
    expect(binding.restore(build, commit: const Commit.fixture()), bytes);
    expect(binding.restore(build, commit: const Commit.fixture()), isNull,
        reason: 'a second controller of the build restores nothing');
    expect(binding.frame(one, commit: const Commit.fixture()).restores,
        isFalse);
  });

  test('a build for another tab drops them (TAB-003)', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture());
    final build = binding.frame(two, commit: const Commit.fixture());
    expect(build.restores, isFalse);
    expect(binding.built, two);
    expect(binding.queued, isNull,
        reason: 'bytes read for a tab no longer being built never land');
    expect(binding.held, isNull);
  });

  test('a later queue replaces an earlier one', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture())
      ..queue(Uint8List.fromList([9]), tab: two, commit: const Commit.fixture());
    expect(binding.queuedFor, two);
    expect(binding.frame(one, commit: const Commit.fixture()).restores,
        isFalse);
  });

  test('a let-go before the controller came queues the back stack again for '
      'the next build (TAB-003)', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture());
    final lost = binding.frame(one, commit: const Commit.fixture());
    binding.letGo(commit: const Commit.fixture());
    expect(binding.built, isNull);
    expect(binding.queuedFor, one);
    expect(binding.restore(lost, commit: const Commit.fixture()), isNull,
        reason: 'the let-go build restores nothing');
    final next = binding.frame(one, commit: const Commit.fixture());
    expect(binding.restore(next, commit: const Commit.fixture()), bytes);
  });

  test('an unbind drops what the build held', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture());
    final build = binding.frame(one, commit: const Commit.fixture());
    binding.unbind(commit: const Commit.fixture());
    expect(binding.held, isNull);
    expect(binding.queued, isNull);
    expect(binding.restore(build, commit: const Commit.fixture()), isNull);
  });

  test('the webview going unbinds it', () {
    final binding = WebViewTabBinding();
    binding.frame(one, commit: const Commit.fixture());
    binding.unbind(commit: const Commit.fixture());
    expect(binding.built, isNull);
  });
}
