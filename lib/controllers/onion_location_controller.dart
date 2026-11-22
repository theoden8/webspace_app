import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/onion_location.dart';
import 'package:webspace/services/onion_location_check.dart';
import 'package:webspace/services/onion_location_engine.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// What the onion flow asks the user.
abstract interface class OnionPrompts {
  /// Whether the site named [site] should load from the onion address it
  /// announced, [onion]; null when the dialog is dismissed, which asks again
  /// at the next check (ONION-003).
  Future<OnionAnswer?> offerOnion({required String site, required String onion});
}

/// Learning a site's onion address from its own answer and asking the user
/// about it (ONION-001, ONION-003, ONION-008).
class OnionLocationController {
  OnionLocationController(
    this._sites, {
    required PageHost host,
    required OnionPrompts prompts,
    required Future<void> Function() settingsSaved,
    DateTime Function()? clock,
    Future<OnionCheck> Function(WebViewModel site)? check,
  }) : _host = host,
       _prompts = prompts,
       _settingsSaved = settingsSaved,
       _clock = clock ?? DateTime.now,
       _check = check ?? _checkOver;

  final SiteRuntime _sites;
  final PageHost _host;
  final OnionPrompts _prompts;

  /// Persists the sites and builds the shown site's webview again, so a
  /// posture that changed takes effect (`SiteResetController.settingsSaved`).
  final Future<void> Function() _settingsSaved;
  final DateTime Function() _clock;
  final Future<OnionCheck> Function(WebViewModel site) _check;

  /// The sites checked this run: each at most once (ONION-008).
  final Set<SiteId> _checked = <SiteId>{};
  final _offer = ReentryGuard();

  static Future<OnionCheck> _checkOver(WebViewModel site) =>
      checkOnionLocation(site.initUrl,
          proxy: site.outboundProxy,
          withinSite: (target) => site.matchesSiteClaim(target.toString()));

  /// [source]'s first live page this build, [url]: checks the site when it
  /// is due, saves what the answer teaches, and offers a new address while
  /// the site is on screen.
  Future<void> firstPageLoaded(WebViewModel source, {required String url}) async {
    if (source.runsForeignTab) return;
    final site = source.runningIdentity;
    if (!onionCheckDue(site.onionLocation,
        tor: site.outboundProxy.carriesTor, pageUrl: url, now: _clock())) {
      return;
    }
    if (!_checked.add(site.siteId)) return;
    final found = await _check(site);
    if (!_host.mounted || !_sites.models.holdsObject(site)) return;
    final inUse = site.onionRoute != null;
    switch (learnFrom(found, saved: site.onionLocation, now: _clock())) {
      case OnionKept():
        return;
      case OnionForgotten():
        site.onionLocation = null;
        await (inUse ? _settingsSaved() : _host.commitSites(const SitesEdited()));
      case OnionLearned(:final onion, :final asks):
        site.onionLocation = onion;
        await _host.commitSites(const SitesEdited());
        if (asks) await _ask(source, site: site, onion: onion);
    }
  }

  Future<void> _ask(
    WebViewModel source, {
    required WebViewModel site,
    required SiteOnion onion,
  }) => _offer.run(() async {
    if (!_host.mounted || !_sites.fore || !identical(_sites.shown, source)) {
      return;
    }
    final answer = await _prompts.offerOnion(
        site: site.getDisplayName(), onion: Uri.parse(onion.endpoint.to).host);
    if (answer == null || !_host.mounted || !_sites.models.holdsObject(site)) {
      return;
    }
    final saved = site.onionLocation;
    if (saved == null || saved.endpoint != onion.endpoint) return;
    site.onionLocation =
        saved.choosing(answer: answer, fallback: saved.fallback);
    final takesEffect = answer == OnionAnswer.accepted &&
        site.onionRoute != null &&
        identical(_sites.shown, source);
    await (takesEffect
        ? _settingsSaved()
        : _host.commitSites(const SitesEdited()));
  });
}
