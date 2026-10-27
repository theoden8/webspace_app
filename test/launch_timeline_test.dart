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
}
