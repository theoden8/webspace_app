import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/http_auth_engine.dart';

/// Models the store's contract: one credential per (siteId, host, realm).
class _MemoryStore implements HttpAuthCredentialStore {
  final Map<String, HttpAuthCredential> entries = {};
  int lookups = 0;

  static String _key(String siteId, String host, String realm) =>
      '$siteId|$host|$realm';

  @override
  Future<HttpAuthCredential?> lookup(
      String siteId, String host, String realm) async {
    lookups++;
    return entries[_key(siteId, host, realm)];
  }

  @override
  Future<void> save(String siteId, String host, String realm,
      HttpAuthCredential credential) async {
    entries[_key(siteId, host, realm)] = credential;
  }

  @override
  Future<void> remove(String siteId, String host, String realm) async {
    entries.remove(_key(siteId, host, realm));
  }
}

/// A prompt that records every request and answers from a queue.
class _ScriptedPrompt {
  final List<HttpAuthPromptRequest> requests = [];
  final List<HttpAuthPromptResult?> answers;
  _ScriptedPrompt(this.answers);

  Future<HttpAuthPromptResult?> call(HttpAuthPromptRequest request) async {
    requests.add(request);
    return answers.removeAt(0);
  }
}

const _alice = HttpAuthCredential(username: 'alice', password: 's3cret');

HttpAuthSession _session({
  required _MemoryStore store,
  HttpAuthPrompt? prompt,
  HttpAuthMemory memory = HttpAuthMemory.readWrite,
  String? siteId = 'site-1',
  String siteUrl = 'https://nas.example.com/files/',
}) =>
    HttpAuthSession(
      siteId: siteId,
      siteUrl: siteUrl,
      memory: memory,
      store: store,
      prompt: prompt,
    );

HttpAuthChallengeInfo _challenge({
  String host = 'nas.example.com',
  String? realm = 'Restricted',
  bool isProxy = false,
  bool platformRetry = false,
}) =>
    HttpAuthChallengeInfo(
      host: host,
      realm: realm,
      isProxy: isProxy,
      platformRetry: platformRetry,
    );

void main() {
  group('HttpAuthSession.isSiteHost', () {
    test('matches every host on the site\'s base domain', () {
      const site = 'https://nas.example.com/';
      expect(HttpAuthSession.isSiteHost('nas.example.com', site), isTrue);
      expect(HttpAuthSession.isSiteHost('NAS.Example.com.', site), isTrue);
      expect(HttpAuthSession.isSiteHost('a.nas.example.com', site), isTrue);
      expect(HttpAuthSession.isSiteHost('example.com', site), isTrue);
      expect(HttpAuthSession.isSiteHost('files.example.com', site), isTrue);
      expect(HttpAuthSession.isSiteHost('files.example.co.uk',
          'https://nas.example.co.uk/'), isTrue);
    });

    test('rejects other registrable domains', () {
      const site = 'https://nas.example.com/';
      expect(HttpAuthSession.isSiteHost('evil.com', site), isFalse);
      expect(HttpAuthSession.isSiteHost('nas.example.com.evil.com', site),
          isFalse);
      expect(HttpAuthSession.isSiteHost('example.co.uk',
          'https://nas.other.co.uk/'), isFalse);
    });

    test('a private suffix is not a site', () {
      const site = 'https://victim.github.io/';
      expect(HttpAuthSession.isSiteHost('attacker.github.io', site), isFalse);
      expect(HttpAuthSession.isSiteHost('github.io', site), isFalse);
    });

    test('matches IP literals and bracketed IPv6 exactly', () {
      expect(HttpAuthSession.isSiteHost('192.168.1.10', 'http://192.168.1.10:8080/'),
          isTrue);
      expect(HttpAuthSession.isSiteHost('192.168.1.11', 'http://192.168.1.10/'),
          isFalse);
      expect(HttpAuthSession.isSiteHost('[::1]', 'http://[::1]:8080/'), isTrue);
    });

    test('a site without a host matches nothing', () {
      expect(HttpAuthSession.isSiteHost('example.com', null), isFalse);
      expect(HttpAuthSession.isSiteHost('example.com', 'file:///x.html'),
          isFalse);
    });
  });

  group('HttpAuthSession.answer', () {
    test('HTTPAUTH-002: another site\'s challenge is left to the platform',
        () async {
      final store = _MemoryStore();
      final prompt = _ScriptedPrompt([]);
      final session = _session(store: store, prompt: prompt.call);

      expect(await session.answer(_challenge(host: 'tracker.test')), isNull);
      expect(prompt.requests, isEmpty);
      expect(store.lookups, 0);
    });

    test('a proxy challenge is left to the proxy settings', () async {
      final store = _MemoryStore();
      final prompt = _ScriptedPrompt([]);
      final session = _session(store: store, prompt: prompt.call);

      expect(await session.answer(_challenge(isProxy: true)), isNull);
      expect(prompt.requests, isEmpty);
    });

    test('HTTPAUTH-003: first challenge prompts and answers with the input',
        () async {
      final store = _MemoryStore();
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(username: 'alice', password: 's3cret'),
      ]);
      final session = _session(store: store, prompt: prompt.call);

      expect(await session.answer(_challenge()), _alice);
      expect(prompt.requests.single.host, 'nas.example.com');
      expect(prompt.requests.single.isRetry, isFalse);
      expect(prompt.requests.single.canRemember, isTrue);
      expect(store.entries, isEmpty,
          reason: 'nothing is saved unless the user ticks remember');
    });

    test('cancel leaves the challenge to the platform', () async {
      final prompt = _ScriptedPrompt([null]);
      final session = _session(store: _MemoryStore(), prompt: prompt.call);

      expect(await session.answer(_challenge()), isNull);
    });

    test('no prompt wired and nothing saved: left to the platform', () async {
      final session = _session(store: _MemoryStore());
      expect(await session.answer(_challenge()), isNull);
    });

    test('HTTPAUTH-004: remember saves under (siteId, host, realm)', () async {
      final store = _MemoryStore();
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(
            username: 'alice', password: 's3cret', remember: true),
      ]);
      final session = _session(store: store, prompt: prompt.call);

      await session.answer(_challenge(host: 'NAS.example.com'));
      expect(store.entries, {'site-1|nas.example.com|Restricted': _alice});
    });

    test('HTTPAUTH-004: a saved credential answers without a prompt', () async {
      final store = _MemoryStore()
        ..entries['site-1|nas.example.com|Restricted'] = _alice;
      final prompt = _ScriptedPrompt([]);
      final session = _session(store: store, prompt: prompt.call);

      expect(await session.answer(_challenge()), _alice);
      expect(prompt.requests, isEmpty);
    });

    test('a saved credential is scoped to its site, host and realm', () async {
      final store = _MemoryStore()
        ..entries['site-2|nas.example.com|Restricted'] = _alice
        ..entries['site-1|nas.example.com|Other'] = _alice;
      final prompt = _ScriptedPrompt([null]);
      final session = _session(store: store, prompt: prompt.call);

      expect(await session.answer(_challenge()), isNull);
      expect(prompt.requests, hasLength(1));
    });

    test('HTTPAUTH-005: a refused saved credential re-prompts once, marked retry',
        () async {
      final store = _MemoryStore()
        ..entries['site-1|nas.example.com|Restricted'] = _alice;
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(
            username: 'alice', password: 'n3w', remember: true),
      ]);
      final session = _session(store: store, prompt: prompt.call);

      expect(await session.answer(_challenge()), _alice);
      final second = await session.answer(_challenge());

      expect(second?.password, 'n3w');
      final request = prompt.requests.single;
      expect(request.isRetry, isTrue);
      expect(request.initialUsername, 'alice');
      expect(request.rememberByDefault, isTrue);
      expect(store.entries['site-1|nas.example.com|Restricted']?.password,
          'n3w');
    });

    test('HTTPAUTH-005: platform retry skips the saved credential', () async {
      final store = _MemoryStore()
        ..entries['site-1|nas.example.com|Restricted'] = _alice;
      final prompt = _ScriptedPrompt([null]);
      final session = _session(store: store, prompt: prompt.call);

      expect(await session.answer(_challenge(platformRetry: true)), isNull);
      expect(prompt.requests.single.isRetry, isTrue);
    });

    test('a typed credential that is refused re-prompts as a retry', () async {
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(username: 'alice', password: 'typo'),
        const HttpAuthPromptResult(username: 'alice', password: 's3cret'),
      ]);
      final session = _session(store: _MemoryStore(), prompt: prompt.call);

      await session.answer(_challenge());
      expect(await session.answer(_challenge()), _alice);
      expect(prompt.requests.map((r) => r.isRetry), [false, true]);
      expect(prompt.requests.map((r) => r.initialUsername), [null, 'alice'],
          reason: 'the retry keeps the username that was sent, even unsaved');
      expect(prompt.requests[1].rememberByDefault, isFalse);
    });

    test('after a cancel the next challenge is a fresh attempt', () async {
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(username: 'alice', password: 'typo'),
        null,
        null,
      ]);
      final session = _session(store: _MemoryStore(), prompt: prompt.call);

      await session.answer(_challenge());
      await session.answer(_challenge());
      await session.answer(_challenge());
      expect(prompt.requests.map((r) => r.isRetry), [false, true, false]);
    });

    test('unticking remember on a retry forgets the saved credential',
        () async {
      final store = _MemoryStore()
        ..entries['site-1|nas.example.com|Restricted'] = _alice;
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(username: 'bob', password: 'x'),
      ]);
      final session = _session(store: store, prompt: prompt.call);

      await session.answer(_challenge());
      await session.answer(_challenge());
      expect(store.entries, isEmpty);
    });

    test('concurrent challenges for one space share one prompt', () async {
      final gate = Completer<HttpAuthPromptResult?>();
      var prompts = 0;
      final session = _session(
        store: _MemoryStore(),
        prompt: (_) {
          prompts++;
          return gate.future;
        },
      );

      final first = session.answer(_challenge());
      final second = session.answer(_challenge());
      await Future<void>.delayed(Duration.zero);
      gate.complete(
          const HttpAuthPromptResult(username: 'alice', password: 's3cret'));

      expect(await first, _alice);
      expect(await second, _alice);
      expect(prompts, 1);
    });

    test('a different realm on the same host is its own prompt', () async {
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(username: 'a', password: '1'),
        const HttpAuthPromptResult(username: 'b', password: '2'),
      ]);
      final session = _session(store: _MemoryStore(), prompt: prompt.call);

      await session.answer(_challenge(realm: 'One'));
      await session.answer(_challenge(realm: 'Two'));
      expect(prompt.requests.map((r) => r.isRetry), [false, false]);
    });
  });

  group('HttpAuthMemory', () {
    test('readOnly (incognito) answers from saved but never saves', () async {
      final store = _MemoryStore()
        ..entries['site-1|nas.example.com|Restricted'] = _alice;
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(
            username: 'bob', password: 'x', remember: true),
      ]);
      final session = _session(
        store: store,
        prompt: prompt.call,
        memory: HttpAuthMemory.readOnly,
      );

      expect(await session.answer(_challenge()), _alice);
      await session.answer(_challenge());
      expect(prompt.requests.single.canRemember, isFalse);
      expect(store.entries['site-1|nas.example.com|Restricted'], _alice,
          reason: 'incognito leaves the saved sign-in as it was');
    });

    test('off (archive-tier) neither reads nor writes the store', () async {
      final store = _MemoryStore()
        ..entries['site-1|nas.example.com|Restricted'] = _alice;
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(
            username: 'bob', password: 'x', remember: true),
      ]);
      final session = _session(
        store: store,
        prompt: prompt.call,
        memory: HttpAuthMemory.off,
      );

      final answer = await session.answer(_challenge());
      expect(answer?.username, 'bob');
      expect(store.lookups, 0);
      expect(prompt.requests.single.canRemember, isFalse);
      expect(store.entries.length, 1);
    });

    test('a webview with no site never touches the store', () async {
      final store = _MemoryStore();
      final prompt = _ScriptedPrompt([
        const HttpAuthPromptResult(
            username: 'bob', password: 'x', remember: true),
      ]);
      final session =
          _session(store: store, prompt: prompt.call, siteId: null);

      await session.answer(_challenge());
      expect(store.lookups, 0);
      expect(store.entries, isEmpty);
      expect(prompt.requests.single.canRemember, isFalse);
    });
  });

  test('a credential never prints its password', () {
    expect('$_alice', isNot(contains('s3cret')));
  });
}
