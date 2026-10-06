import 'package:webspace/services/site_posture.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

/// The posture of a site with every blocker and Tracking Protection off, so a
/// test measures only the path it is about. Built by the app's own resolver,
/// so it is a posture a real site can have; [adjust] sets anything else.
SitePosture barePosture(
  String url, {
  required String siteId,
  UserProxySettings? proxy,
  void Function(WebViewModel site)? adjust,
}) {
  final site = WebViewModel(
    initUrl: url,
    siteId: siteId,
    proxySettings: proxy,
    clearUrlEnabled: false,
    dnsBlockEnabled: false,
    contentBlockEnabled: false,
    trackingProtectionEnabled: false,
  );
  adjust?.call(site);
  return site.sitePosture(globalUserScripts: const []);
}
