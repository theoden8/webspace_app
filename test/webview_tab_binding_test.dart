import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/webview_tab_binding.dart';

void main() {
  final one = TabId.mint();
  final two = TabId.mint();
  final bytes = Uint8List.fromList([1, 2, 3]);

  test('a build for the tab the bytes were read for takes them once', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture());
    binding.bind(one, commit: const Commit.fixture());
    expect(binding.built, one);
    expect(binding.take(tab: one, commit: const Commit.fixture()), bytes);
    expect(binding.take(tab: one, commit: const Commit.fixture()), isNull);
  });

  test('a build for another tab drops them (TAB-003)', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture());
    expect(binding.take(tab: two, commit: const Commit.fixture()), isNull);
    expect(binding.queued, isNull,
        reason: 'bytes read for a tab no longer being built never land');
  });

  test('a later queue replaces an earlier one', () {
    final binding = WebViewTabBinding()
      ..queue(bytes, tab: one, commit: const Commit.fixture())
      ..queue(Uint8List.fromList([9]), tab: two, commit: const Commit.fixture());
    expect(binding.queuedFor, two);
    expect(binding.take(tab: one, commit: const Commit.fixture()), isNull);
  });

  test('the webview going unbinds it', () {
    final binding = WebViewTabBinding()..bind(one, commit: const Commit.fixture());
    binding.unbind(commit: const Commit.fixture());
    expect(binding.built, isNull);
  });
}
