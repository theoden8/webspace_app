import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/app_prefs.dart';

Future<Map<String, Object?>?> shimReadRegistry(Map<String, Object> values) async {
  // Runs as a test inside the release's tree (generate.sh).
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(values);
  return readExportedAppPrefs(await SharedPreferences.getInstance());
}
