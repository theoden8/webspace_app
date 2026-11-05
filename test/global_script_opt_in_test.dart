import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

/// A launch's store over [sites], holding [globals]: what startup has in hand
/// when it runs the migration, after the sites and scripts are read.
ShellStore _launch(List<WebViewModel> sites,
        {required List<UserScriptConfig> globals}) =>
    ShellStore(SiteRuntime()..models.addAll(sites))..globalUserScripts = globals;

void main() {
  final dark = UserScriptConfig(name: 'Dark', source: 'document.body;');
  final ads = UserScriptConfig(name: 'Ads', source: 'void 0;');

  test(
      'US-001d: the first launch after the upgrade opts every site with none '
      'into every global script, once', () async {
    SharedPreferences.setMockInitialValues({});
    final mail = WebViewModel(initUrl: 'https://mail.example/');
    final news = WebViewModel(
        initUrl: 'https://news.example/', enabledGlobalScriptIds: {dark.id});

    expect(await _launch([mail, news], globals: [dark, ads])
        .migrateGlobalScriptOptIn(), isTrue);
    expect(mail.enabledGlobalScriptIds, {dark.id, ads.id});
    expect(news.enabledGlobalScriptIds, {dark.id});

    mail.enabledGlobalScriptIds = {};
    expect(await _launch([mail, news], globals: [dark, ads])
        .migrateGlobalScriptOptIn(), isFalse);
    expect(mail.enabledGlobalScriptIds, isEmpty,
        reason: 'the user opted it out since');
  });

  // The marker was set only when the fill ran, so a new install, whose first
  // launch has no scripts, kept checking: the launch after the user added
  // one opted into it every site the user had left out.
  test(
      'US-001d: a script added after a launch with none is the opt-in '
      "model's, so the sites left out of it stay out", () async {
    SharedPreferences.setMockInitialValues({});
    final mail = WebViewModel(initUrl: 'https://mail.example/');

    await _launch([mail], globals: const []).migrateGlobalScriptOptIn();
    final news = WebViewModel(
        initUrl: 'https://news.example/', enabledGlobalScriptIds: {dark.id});

    expect(await _launch([mail, news], globals: [dark])
        .migrateGlobalScriptOptIn(), isFalse);
    expect(mail.enabledGlobalScriptIds, isEmpty,
        reason: 'the user added Dark and left this site out of it');
  });
}
