import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/launch_timeline.dart';
import 'package:webspace/services/log_service.dart';

/// One App logs line per launch, naming each phase it reached (DEVTOOLS-013).
void main() {
  setUp(() {
    LaunchTimeline.resetForTest();
    LogService.instance.resetForTest();
  });

  List<String> launchLines() => [
        for (final e in LogService.instance.recent({LogTag.startup}, limit: 10))
          if (e.message.startsWith('Launch')) e.message,
      ];

  test('reports the phases reached, in launch order, once', () {
    LaunchTimeline.start();
    LaunchTimeline.reached(LaunchMark.activated);
    LaunchTimeline.reached(LaunchMark.runApp);
    LaunchTimeline.reached(LaunchMark.runApp);
    LaunchTimeline.end();
    LaunchTimeline.reached(LaunchMark.pageSettled);
    LaunchTimeline.end();

    expect(launchLines(), hasLength(1));
    expect(launchLines().single,
        matches(RegExp(r'^Launch, from main\(\): runApp \d+ms, site activated \d+ms$')));
  });

  test('lists the phases in the order the clock reached them', () async {
    LaunchTimeline.start();
    LaunchTimeline.reached(LaunchMark.sitesOnPage);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    LaunchTimeline.reached(LaunchMark.firstFrame);
    LaunchTimeline.end();

    expect(launchLines().single,
        matches(RegExp(r'^Launch, from main\(\): sites on page \d+ms, first frame \d+ms$')),
        reason: 'a first frame that lands after the sites are on the page '
            'reads after them, whatever the declaration order');
  });

  test('names the first time each activation step was marked', () async {
    LaunchTimeline.start();
    LaunchTimeline.reached(LaunchMark.runApp);
    LaunchTimeline.stepReached(ActivationStep.tap);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    LaunchTimeline.stepReached(ActivationStep.goHome);
    LaunchTimeline.stepReached(ActivationStep.tap);
    LaunchTimeline.end();

    expect(launchLines().single,
        matches(RegExp(r'^Launch, from main\(\): runApp \d+ms; '
            r'activation steps: tap (\d+)ms, goHome \d+ms$')));
  });

  test('a process whose main() never started the clock reports nothing', () {
    LaunchTimeline.reached(LaunchMark.runApp);
    LaunchTimeline.end();
    expect(launchLines(), isEmpty);
  });

  group('switch timeline (after launch)', () {
    List<String> switchLines() => [
          for (final e
              in LogService.instance.recent({LogTag.startup}, limit: 20))
            if (e.message.startsWith('Switch')) e.message,
        ];

    // Opens the door to switch timing: the launch is over.
    void launchEnded() {
      LaunchTimeline.start();
      LaunchTimeline.end();
    }

    test('a visible switch reports its phases from the tap, once', () async {
      launchEnded();
      LaunchTimeline.stepReached(ActivationStep.tap); // the tap anchors it
      await Future<void>.delayed(const Duration(milliseconds: 5));
      LaunchTimeline.stepReached(ActivationStep.commit); // activated
      LaunchTimeline.reached(LaunchMark.webViewBuilt);
      LaunchTimeline.reached(LaunchMark.pageStarted);
      LaunchTimeline.reached(LaunchMark.pageSettled); // emits here

      expect(switchLines(), hasLength(1));
      expect(
          switchLines().single,
          matches(RegExp(r'^Switch: tap 0ms, site activated \d+ms, '
              r'webview built \d+ms, page started \d+ms, '
              r'page settled \d+ms$')));
    });

    test('the commit step is the activated phase', () {
      launchEnded();
      LaunchTimeline.stepReached(ActivationStep.spaceSwitch);
      LaunchTimeline.stepReached(ActivationStep.commit);
      LaunchTimeline.reached(LaunchMark.pageSettled);
      expect(switchLines().single, contains('site activated'));
    });

    test('a second tap supersedes and reports the first', () {
      launchEnded();
      LaunchTimeline.stepReached(ActivationStep.tap);
      LaunchTimeline.reached(LaunchMark.webViewBuilt);
      // No page settle: the next tap supersedes and reports this one.
      LaunchTimeline.stepReached(ActivationStep.openTab);
      LaunchTimeline.reached(LaunchMark.pageSettled);

      expect(switchLines(), hasLength(2));
      expect(switchLines().first, contains('webview built'));
      expect(switchLines().last, contains('page settled'));
    });

    test('an off-screen flow opens no segment', () {
      launchEnded();
      LaunchTimeline.stepReached(ActivationStep.preload);
      LaunchTimeline.reached(LaunchMark.webViewBuilt);
      LaunchTimeline.reached(LaunchMark.pageSettled);
      expect(switchLines(), isEmpty);
    });

    test('phases before the launch ends belong to the launch, not a switch',
        () {
      LaunchTimeline.start();
      LaunchTimeline.stepReached(ActivationStep.tap);
      LaunchTimeline.reached(LaunchMark.pageSettled);
      LaunchTimeline.end();
      expect(switchLines(), isEmpty);
      expect(launchLines(), hasLength(1));
    });
  });
}
