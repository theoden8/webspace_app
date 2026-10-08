import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity.dart';

/// The navigator identity the engine of a UA really reports. A null `oscpu` or
/// `buildID` is removed from the navigator, not stubbed; a null `platform` is
/// left to the host.
typedef UaIdentity = ({
  String vendor,
  String productSub,
  String? oscpu,
  String? buildID,
  String? platform,
  bool removeUserAgentData,
});

/// The engine-consistent navigator-identity shim for [userAgent], or `null`
/// when the engine can't be classified (nothing to enforce) or the UA is
/// empty.
String? buildUserAgentIdentityShim(String userAgent) =>
    switch (uaIdentityFor(userAgent)) {
      null => null,
      final id => PageJs.uaIdentity.withConfig({
          'vendor': id.vendor,
          'productSub': id.productSub,
          'oscpu': id.oscpu,
          'buildID': id.buildID,
          'platform': id.platform,
          'removeUserAgentData': id.removeUserAgentData,
        }),
    };

/// The identity [userAgent]'s engine reports; lib/js/ua_identity.js lists
/// each value and where it comes from.
UaIdentity? uaIdentityFor(String userAgent) {
  final engine = inferUaEngine(userAgent);
  if (engine == UaEngine.unknown) return null;

  final os = describeUserAgent(userAgent).os;
  final isGecko = engine == UaEngine.gecko;
  final isMobile = !isDesktopUserAgent(userAgent);

  final vendor = switch (engine) {
    UaEngine.gecko => '',
    UaEngine.webkit => 'Apple Computer, Inc.',
    UaEngine.blink => 'Google Inc.',
    UaEngine.unknown => '',
  };
  final productSub = isGecko ? '20100101' : '20030107';

  final String? oscpu = isGecko
      ? switch (os) {
          UaOs.linux => 'Linux x86_64',
          UaOs.windows => 'Windows NT 10.0; Win64; x64',
          UaOs.macos => 'Intel Mac OS X 10.15',
          UaOs.android => 'Linux armv8l',
          _ => null,
        }
      : null;

  // Set for every UA we can place, not just mobile: worker scopes get this
  // shim but never desktop_mode.js (which is window-only — viewport meta,
  // touch, pointer/hover matchMedia), so a desktop-UA worker would otherwise
  // report the host's real platform. On the page this re-asserts the value
  // desktop_mode.js already set; both derive it from the same UA mapping,
  // so they cannot disagree.
  final String? platform = isMobile
      ? switch ((engine, os)) {
          (UaEngine.gecko, UaOs.android) => 'Linux armv8l',
          (UaEngine.blink, UaOs.android) => 'Linux armv8l',
          (UaEngine.webkit, UaOs.ios) => 'iPhone',
          _ => null,
        }
      : navigatorPlatformFor(inferDesktopUaPlatform(userAgent));

  // userAgentData exists only on Blink. Remove it for Gecko/WebKit UAs
  // (desktop_mode.js already removes it for desktop UAs, so only mobile
  // needs it here).
  final removeUserAgentData = isMobile && engine != UaEngine.blink;

  return (
    vendor: vendor,
    productSub: productSub,
    oscpu: oscpu,
    buildID: isGecko ? '20181001000000' : null,
    platform: platform,
    removeUserAgentData: removeUserAgentData,
  );
}
