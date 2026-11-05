import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  test(
      'BGAUDIO-004: a background-audio site shares the notification tier and '
      'outlives every ordinary site under pressure', () {
    final radio = WebViewModel(
        initUrl: 'https://radio.example/', backgroundAudioEnabled: true);
    final chat = WebViewModel(
        initUrl: 'https://chat.example/', notificationsEnabled: true);
    final news = WebViewModel(initUrl: 'https://news.example/');
    final runtime = SiteRuntime()..models.addAll([radio, chat, news]);
    runtime.seed(loaded: [radio, chat, news]);

    expect(runtime.retentionPriority(0), SiteRetentionPriority.notification);
    expect(runtime.retentionPriority(1), SiteRetentionPriority.notification);
    expect(runtime.retentionPriority(2), isNot(SiteRetentionPriority.notification));
    expect(runtime.firstToEvict([radio, chat, news]), same(news),
        reason: 'the ordinary site goes first, though it is the most recent');
    expect(runtime.firstToEvict([radio, chat]), same(radio),
        reason: 'within the tier, least recently used first');
  });
}
