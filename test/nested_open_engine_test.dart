import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/nested_open_engine.dart';

/// Models the app around a nested open: a site list, the loaded set, one
/// process-global proxy, and the active site. Records every step, and fails
/// the test the moment a loaded site's proxy differs from the applied one,
/// which is the leak PROXY-008 exists to prevent.
class _FakeHost implements NestedOpenHost<String> {
  _FakeHost({
    required this.sites,
    required this.proxyOf,
    required Set<int> loaded,
    required this.currentIndex,
    this.proxyIsProcessGlobal = true,
  })  : loaded = {...loaded},
        applied = currentIndex == null ? null : proxyOf[sites[currentIndex]];

  final List<String> sites;
  final Map<String, String> proxyOf;
  final Set<int> loaded;
  String? applied;

  @override
  int? currentIndex;
  @override
  bool mounted = true;
  @override
  final bool proxyIsProcessGlobal;

  bool failApply = false;
  void Function()? duringScreen;
  void Function()? afterFirstUnload;
  final events = <String>[];

  void _checkNoLeak() {
    if (!proxyIsProcessGlobal) return;
    for (final i in loaded) {
      expect(proxyOf[sites[i]], applied,
          reason: '${sites[i]} is loaded under another site\'s proxy '
              '(events: $events)');
    }
  }

  @override
  int indexOf(String site) => sites.indexOf(site);

  @override
  Future<void> switchWebspaceFor(String target) async =>
      events.add('switchWebspace $target');

  @override
  Set<int> mismatchedWith(String target) => {
        for (final i in loaded)
          if (proxyOf[sites[i]] != proxyOf[target]) i,
      };

  @override
  Future<void> unload(int index) async {
    events.add('unload ${sites[index]}');
    loaded.remove(index);
    final hook = afterFirstUnload;
    afterFirstUnload = null;
    hook?.call();
  }

  @override
  Future<void> applyProxyOf(String target) async {
    if (failApply) throw StateError('proxy refused');
    events.add('apply ${proxyOf[target]}');
    applied = proxyOf[target];
    _checkNoLeak();
  }

  @override
  void reportProxyFailure(Object error) => events.add('refused');

  @override
  Future<void> launchNested(String target, String url) async {
    events.add('screen $target');
    duringScreen?.call();
    events.add('pop');
  }

  @override
  Future<void> activate(int index) async {
    events.add('activate ${sites[index]}');
    if (proxyIsProcessGlobal) applied = proxyOf[sites[index]];
    loaded.add(index);
    currentIndex = index;
    _checkNoLeak();
  }
}

void main() {
  _FakeHost ddgActive({String ghProxy = 'P2', bool global = true}) =>
      _FakeHost(
        sites: ['ddg', 'gh', 'mail'],
        proxyOf: {'ddg': 'P1', 'gh': ghProxy, 'mail': 'P1'},
        loaded: {0},
        currentIndex: 0,
        proxyIsProcessGlobal: global,
      );

  group('routed open over the source (LIR-015)', () {
    test('the source comes back under its own proxy after the pop', () async {
      final host = ddgActive();
      final outcome = await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x', source: 'ddg');
      expect(outcome, NestedOpenOutcome.opened);
      expect(host.events, [
        'unload ddg',
        'apply P2',
        'screen gh',
        'pop',
        'activate ddg',
      ]);
      expect(host.applied, 'P1');
      expect(host.loaded, {0});
    });

    test('a source on the same proxy stays loaded and is not re-activated',
        () async {
      final host = ddgActive(ghProxy: 'P1');
      await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x', source: 'ddg');
      expect(host.events, ['apply P1', 'screen gh', 'pop']);
      expect(host.loaded, {0});
    });

    test('the webspace is left alone', () async {
      final host = ddgActive();
      await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x', source: 'ddg');
      expect(host.events.where((e) => e.startsWith('switchWebspace')),
          isEmpty);
    });

    test('a refused proxy opens nothing and brings the source back',
        () async {
      final host = ddgActive()..failApply = true;
      final outcome = await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x', source: 'ddg');
      expect(outcome, NestedOpenOutcome.proxyRefused);
      expect(host.events, ['unload ddg', 'refused', 'activate ddg']);
    });

    test('a user who moved on while the screen was up is not pulled back',
        () async {
      final host = ddgActive();
      host.duringScreen = () => host.currentIndex = 2;
      await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x', source: 'ddg');
      expect(host.events.last, 'pop');
    });

    test('a source deleted while the screen was up is not re-activated',
        () async {
      final host = ddgActive();
      host.duringScreen = () => host.sites[0] = 'deleted';
      await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x', source: 'ddg');
      expect(host.events.last, 'pop');
    });

    test('unmounting mid-sequence stops before anything opens', () async {
      final host = ddgActive();
      host.afterFirstUnload = () => host.mounted = false;
      final outcome = await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x', source: 'ddg');
      expect(outcome, NestedOpenOutcome.abandoned);
      expect(host.events, ['unload ddg']);
    });
  });

  group('inbound open (LIR-011)', () {
    test('switches the webspace and does not re-activate anything', () async {
      final host = ddgActive();
      final outcome = await NestedOpenEngine.run(host,
          target: 'gh', url: 'https://github.com/x');
      expect(outcome, NestedOpenOutcome.opened);
      expect(host.events, [
        'switchWebspace gh',
        'unload ddg',
        'apply P2',
        'screen gh',
        'pop',
      ]);
    });
  });

  test('without a process-global proxy nothing is unloaded or applied',
      () async {
    final host = ddgActive(global: false);
    await NestedOpenEngine.run(host,
        target: 'gh', url: 'https://github.com/x', source: 'ddg');
    expect(host.events, ['screen gh', 'pop']);
    expect(host.loaded, {0});
  });
}
