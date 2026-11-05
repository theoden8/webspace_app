import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/isolation.dart';

import 'helpers/mock_container_native.dart';
import 'helpers/mock_cookie_manager.dart';
import 'helpers/mock_secure_storage.dart';

/// CONT-001: one `isSupported()` answer picks how the sites' cookies are
/// kept apart for the run. Driven through `Isolation.probe`, the restore's
/// only way to decide, with the container fake answering either way.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CookieIsolationEngine legacyJar() => CookieIsolationEngine(
        cookieManager: MockCookieManager(),
        storage: CookieSecureStorage(secureStorage: MockFlutterSecureStorage()),
      );

  test('CONT-001: where containers are supported, each site gets its own and '
      'no shared jar is built', () async {
    final native = MockContainerNative(supported: true);
    var jarsBuilt = 0;
    final decided = await Isolation.probe(
      native: native,
      legacy: () {
        jarsBuilt++;
        return legacyJar();
      },
    );
    expect(decided, isA<Containers>());
    expect((decided as Containers).engine.containerNative, same(native));
    expect(jarsBuilt, 0,
        reason: 'a shared jar would put every site behind one cookie store');
    expect(native.calls.where((c) => c == 'isSupported'), hasLength(1),
        reason: 'one answer decides the run');
  });

  test('CONT-001: where they are not, the sites share the legacy jar',
      () async {
    final native = MockContainerNative(supported: false);
    final jar = legacyJar();
    final decided = await Isolation.probe(native: native, legacy: () => jar);
    expect(decided, isA<SharedJar>());
    expect((decided as SharedJar).jar, same(jar));
    expect(native.calls.where((c) => c == 'isSupported'), hasLength(1));
  });
}
