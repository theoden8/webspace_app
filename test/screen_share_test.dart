import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/screen_share.dart';
import 'package:webspace/settings/site_ids.dart';

/// Android's side of a share as the app sees it: a prompt the test answers,
/// frames it hands out, and an end the user can press.
final class FakeAndroidShare implements ScreenShareNative {
  Completer<ShareSize?>? prompt;
  final List<ShareRequest> asked = [];
  final frames = <ShareFrame>[];
  int stops = 0;
  void Function()? _ended;

  @override
  set onEnded(void Function() ended) => _ended = ended;

  /// The user pressed Stop in Android's notification or cast controls.
  void userStops() => _ended?.call();

  @override
  Future<ShareSize?> start({
    required ShareRequest request,
    required ShareNotice notice,
  }) {
    asked.add(request);
    return (prompt = Completer<ShareSize?>()).future;
  }

  @override
  Future<ShareFrame> frame({required int after}) async =>
      frames.isEmpty ? NoNewFrame(after) : frames.removeAt(0);

  @override
  Future<void> stop() async => stops++;
}

const _notice = (title: 'Sharing', text: 'a.example', stop: 'Stop');
const _request = (maxWidth: 0, maxHeight: 0, fps: 10);
const _size = (width: 640, height: 1280);
final _a = (site: SiteId('a'), view: 'wv1');
final _aNested = (site: SiteId('a'), view: 'wv2');
final _b = (site: SiteId('b'), view: 'wv3');

void main() {
  late FakeAndroidShare android;
  late ScreenShare share;

  setUp(() {
    android = FakeAndroidShare();
    share = ScreenShare(native: android);
  });

  Future<ShareSize?> started(ShareOwner owner) async {
    final start = share.start(owner, request: _request, notice: _notice);
    // A share already running is ended before Android is asked again.
    await pumpEventQueue();
    android.prompt!.complete(_size);
    return start;
  }

  group('starting (SHARE-018)', () {
    test("a yes to Android's prompt starts the share for its owner", () async {
      expect(await started(_a), _size);
      expect(share.sharing(SiteId('a')), isTrue);
      expect(share.sharing(SiteId('b')), isFalse);
    });

    test('a no starts nothing', () async {
      final start = share.start(_a, request: _request, notice: _notice);
      android.prompt!.complete(null);
      expect(await start, isNull);
      expect(share.sharing(SiteId('a')), isFalse);
    });

    test('a second request while the prompt is up is refused, not stacked',
        () async {
      final first = share.start(_a, request: _request, notice: _notice);
      expect(await share.start(_a, request: _request, notice: _notice), isNull);
      expect(android.asked, hasLength(1));
      android.prompt!.complete(_size);
      expect(await first, _size);
    });

    test('a site that leaves the screen during the prompt gets no share '
        '(SHARE-017)', () async {
      final start = share.start(_a, request: _request, notice: _notice);
      await share.endSite(SiteId('a'));
      android.prompt!.complete(_size);
      expect(await start, isNull);
      expect(share.sharing(SiteId('a')), isFalse);
      expect(android.stops, 1, reason: 'the projection Android began is ended');
    });

    test('a page that navigates during the prompt gets no share', () async {
      final start = share.start(_a, request: _request, notice: _notice);
      await share.endView('wv1');
      android.prompt!.complete(_size);
      expect(await start, isNull);
    });

    test('another site leaving the screen does not cancel the prompt',
        () async {
      final start = share.start(_a, request: _request, notice: _notice);
      await share.endSite(SiteId('b'));
      android.prompt!.complete(_size);
      expect(await start, _size);
    });

    test('a new share ends the one before it: one at a time', () async {
      await started(_a);
      await started(_b);
      expect(android.stops, 1);
      expect(share.sharing(SiteId('a')), isFalse);
      expect(share.sharing(SiteId('b')), isTrue);
    });
  });

  group('frames', () {
    test('only the webview that started the share reads it', () async {
      await started(_a);
      android.frames.add(FrameReady(seq: 1, jpeg: Uint8List.fromList([1])));
      expect(await share.frame(_aNested, after: 0), isA<ShareEnded>(),
          reason: 'a nested screen of the same site is not the owner');
      expect(await share.frame(_b, after: 0), isA<ShareEnded>());
      expect(await share.frame(_a, after: 0), isA<FrameReady>());
    });

    test('a frame Android reports ended clears the share', () async {
      await started(_a);
      android.frames.add(const ShareEnded());
      expect(await share.frame(_a, after: 0), isA<ShareEnded>());
      expect(share.sharing(SiteId('a')), isFalse);
    });

    test('a pull that returns after the share ended reads as ended', () async {
      final slow = Completer<ShareFrame>();
      final native = _Slow(android, frame: slow.future);
      final s = ScreenShare(native: native);
      final start = s.start(_a, request: _request, notice: _notice);
      android.prompt!.complete(_size);
      await start;
      final pull = s.frame(_a, after: 0);
      await s.endSite(SiteId('a'));
      slow.complete(FrameReady(seq: 1, jpeg: Uint8List(1)));
      expect(await pull, isA<ShareEnded>());
    });

    test('the bridge shapes', () {
      expect(FrameReady(seq: 3, jpeg: Uint8List.fromList([255, 216]))
          .toBridgeJson(), {'seq': 3, 'jpeg': '/9g='});
      expect(const NoNewFrame(3).toBridgeJson(), {'seq': 3});
      expect(const ShareEnded().toBridgeJson(), {'ended': true});
    });
  });

  group('ending (SHARE-017)', () {
    test("the page's stop ends only its own share", () async {
      await started(_a);
      await share.stop(_aNested);
      expect(share.sharing(SiteId('a')), isTrue);
      await share.stop(_a);
      expect(share.sharing(SiteId('a')), isFalse);
      expect(android.stops, 1);
    });

    test('the site leaving the screen ends it', () async {
      await started(_a);
      await share.endSite(SiteId('b'));
      expect(share.sharing(SiteId('a')), isTrue);
      await share.endSite(SiteId('a'));
      expect(share.sharing(SiteId('a')), isFalse);
      expect(android.stops, 1);
    });

    test("the user's stop from Android ends it without asking Android again",
        () async {
      await started(_a);
      android.userStops();
      expect(share.sharing(SiteId('a')), isFalse);
      expect(await share.frame(_a, after: 0), isA<ShareEnded>());
      expect(android.stops, 0);
    });

    test('no pull for the idle limit ends it; pulls keep it going', () {
      fakeAsync((async) {
        final s = ScreenShare(
          native: android,
          idle: const Duration(seconds: 8),
          now: () => async.getClock(DateTime(2026)).now(),
        );
        unawaited(s.start(_a, request: _request, notice: _notice));
        android.prompt!.complete(_size);
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(seconds: 3));
          unawaited(s.frame(_a, after: 0));
          async.flushMicrotasks();
        }
        expect(s.sharing(SiteId('a')), isTrue);
        async.elapse(const Duration(seconds: 10));
        expect(s.sharing(SiteId('a')), isFalse);
        expect(android.stops, 1);
      });
    });
  });

  group('what the page asks', () {
    test('caps are bounded and anything else reads as the defaults', () {
      expect(shareRequestFromPage({'maxWidth': 800, 'maxHeight': 0, 'fps': 60}),
          (maxWidth: 800, maxHeight: 0, fps: ShareLimits.maxFps));
      expect(shareRequestFromPage({'maxWidth': -4, 'maxHeight': 'x', 'fps': 0}),
          (maxWidth: 0, maxHeight: 0, fps: 1));
      expect(shareRequestFromPage('bogus'),
          (maxWidth: 0, maxHeight: 0, fps: ShareLimits.maxFps));
    });
  });
}

/// [FakeAndroidShare] whose frame call waits on [_frame].
final class _Slow implements ScreenShareNative {
  _Slow(this._inner, {required Future<ShareFrame> frame}) : _frame = frame;
  final FakeAndroidShare _inner;
  final Future<ShareFrame> _frame;

  @override
  set onEnded(void Function() ended) => _inner.onEnded = ended;

  @override
  Future<ShareSize?> start({
    required ShareRequest request,
    required ShareNotice notice,
  }) =>
      _inner.start(request: request, notice: notice);

  @override
  Future<ShareFrame> frame({required int after}) => _frame;

  @override
  Future<void> stop() => _inner.stop();
}
