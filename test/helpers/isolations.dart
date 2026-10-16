import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/isolation.dart';

import 'mock_container_native.dart';
import 'mock_cookie_manager.dart';
import 'mock_secure_storage.dart';

/// The legacy engine over [cookies], a fresh fake jar unless given, its
/// stored sessions in a fake keychain.
SharedJar fakeSharedJar({CookieManager? cookies}) => SharedJar(
  CookieIsolationEngine(
    cookieManager: cookies ?? MockCookieManager(),
    storage: CookieSecureStorage(secureStorage: MockFlutterSecureStorage()),
  ),
);

/// Native containers over [native], a fake that supports them unless given.
Containers fakeContainers({ContainerNative? native}) => Containers(
  engine: ContainerIsolationEngine(
    containerNative: native ?? MockContainerNative(),
  ),
);
