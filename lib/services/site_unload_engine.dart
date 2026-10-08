import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/site_activation_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

/// Default cap on concurrently loaded webviews. Keeps memory bounded when
/// container mode lets sites stay resident across webspace switches; without
/// it, a heavy user could accumulate dozens of live native webviews.
const int kMaxLoadedSites = 20;

/// Why a loaded site leaves the loaded set, short of being deleted. The label
/// is what the background log names (DEVTOOLS-011).
enum UnloadReason {
  domainConflict('domain conflict'),
  proxyMismatch('proxy mismatch'),
  torExitMismatch('Tor exit-country mismatch'),
  loadedSiteCap('loaded-site cap'),
  memoryPressure('memory pressure'),
  webspaceSwitch('webspace switch'),

  /// An always-open-home or incognito site sent back to its home page: by a
  /// shortcut launch, or before a link opens in it (LIR-011).
  homeReset('home reset');

  const UnloadReason(this.label);

  final String label;

  /// Whether the back stack is saved for the next activation (PAUSE-007).
  bool get keepsNavState => switch (this) {
        UnloadReason.domainConflict ||
        UnloadReason.proxyMismatch ||
        UnloadReason.torExitMismatch ||
        UnloadReason.loadedSiteCap ||
        UnloadReason.memoryPressure ||
        UnloadReason.webspaceSwitch =>
          true,
        // It goes back to its home page, which is the point (always-open-home).
        UnloadReason.homeReset => false,
      };

  /// An unload the user did not ask for and will notice logs as a warning.
  LogLevel get logLevel => switch (this) {
        UnloadReason.domainConflict ||
        UnloadReason.proxyMismatch ||
        UnloadReason.torExitMismatch ||
        UnloadReason.memoryPressure =>
          LogLevel.warning,
        UnloadReason.loadedSiteCap ||
        UnloadReason.webspaceSwitch ||
        UnloadReason.homeReset =>
          LogLevel.info,
      };
}

/// What [SiteUnloadEngine.unload] reads and writes on the page.
abstract interface class SiteUnloadHost {
  List<WebViewModel> get models;
  Set<int> get loadedIndices;

  /// The legacy engine, whose sites share one cookie jar; null under
  /// containers, where each site's jar is its own.
  CookieIsolationEngine? get sharedJar;

  /// Saves [model]'s back stack for its next activation.
  Future<void> captureNavState(WebViewModel model);

  void noteUnloaded(WebViewModel model, UnloadReason reason);
}

/// What [SiteUnloadEngine.plan] reads beyond what an unload needs.
abstract interface class ResidencyHost implements SiteUnloadHost {
  /// What each slot runs as (LIR-024): a slot showing a hosted tab reads as
  /// its host. The slot at [except] reads as its own site.
  List<WebViewModel> identities({int? except});

  SiteRetentionPriority priorityOf(int index);

  ProxyTopology get proxyTopology;

  /// Whether a Tor runtime exists here, so loaded sites can disagree about
  /// its exit country (TOR-014).
  bool get torAvailable;
}

/// What can change which sites stay loaded. [SiteUnloadEngine.plan] answers
/// every kind in one switch, so a new event is a case it must handle.
sealed class ResidencyEvent {
  const ResidencyEvent();
}

/// [target] is about to be shown: the loaded sites it conflicts with go
/// (ISO-001, PROXY-008, TOR-014), then whatever the loaded-site cap and the
/// resident cap take (PAUSE-012).
final class Activating extends ResidencyEvent {
  const Activating(this.target);

  final int target;
}

/// The OS asked for memory back: one loaded site moves one tier down
/// (PAUSE-006).
final class MemoryPressure extends ResidencyEvent {
  const MemoryPressure();
}

/// The selected webspace changed from the sites at [previous] to those at
/// [next]. Only a shared cookie jar unloads for it (CONT-003).
final class WebspaceSwitched extends ResidencyEvent {
  const WebspaceSwitched({required this.previous, required this.next});

  final Set<int> previous;
  final Set<int> next;
}

/// A setting changed under loaded sites: the first Tor site in [order]
/// decides the exit pin, and the loaded Tor sites that want another go
/// before it is put in force (TOR-014).
final class TorExitSettled extends ResidencyEvent {
  const TorExitSettled(this.order);

  final Iterable<int> order;
}

/// A nested screen is about to run as [target] under its proxy, which
/// loaded sites contending for the same proxy cannot share (SEC-004).
final class NestedOpening extends ResidencyEvent {
  const NestedOpening(this.target);

  final int target;
}

/// The slot on screen at [slot] now runs as another site, so its proxy may
/// have changed under its contenders (LIR-024).
final class SlotIdentityChanged extends ResidencyEvent {
  const SlotIdentityChanged(this.slot);

  final int slot;
}

/// What a [ResidencyEvent] does to the loaded sites. Sites rather than
/// positions: a delete can shift the list while the plan runs.
final class ResidencyPlan {
  const ResidencyPlan({this.unloads = const [], this.cacheClears = const []});

  static const none = ResidencyPlan();

  /// In the order they run.
  final List<({WebViewModel site, UnloadReason reason})> unloads;

  /// Resident sites whose cache is cleared once the unloads ran.
  final List<WebViewModel> cacheClears;

  bool get isEmpty => unloads.isEmpty && cacheClears.isEmpty;
}

/// How the host scopes a proxy, which decides who contends for it when a
/// site with another proxy activates (PROXY-008, PROXY-013). Built only by
/// [ProxyTopology.of], so no caller can name a topology the host and the
/// router state did not produce.
sealed class ProxyTopology {
  const ProxyTopology();

  /// Linux has no router. Android is process-global until the router runs;
  /// [sharesDefaultSession] then names the sites that still share one
  /// credential. iOS and macOS bind per session.
  factory ProxyTopology.of({
    required bool linux,
    required bool android,
    required bool routerActive,
    required bool Function(WebViewModel model) sharesDefaultSession,
  }) {
    if (linux) return const ProcessGlobalProxy._();
    if (routerActive) return RoutedProxy._(sharesDefaultSession);
    return android ? const ProcessGlobalProxy._() : const PerSessionProxy._();
  }
}

/// iOS and macOS bind a proxy per session: nothing contends.
final class PerSessionProxy extends ProxyTopology {
  const PerSessionProxy._();
}

/// Android without the router, and Linux: one process-global,
/// last-write-wins override (`ProxyController` fanned across sessions).
/// Every loaded site contends.
final class ProcessGlobalProxy extends ProxyTopology {
  const ProcessGlobalProxy._();
}

/// Router mode (PROXY-013): the process-wide rule names the loopback relay
/// and each site presents its own credential, bought by its container
/// profile. A site with no profile runs in the default one, whose single
/// cached credential every other such site presents too, so exactly that
/// group still contends.
final class RoutedProxy extends ProxyTopology {
  const RoutedProxy._(this.sharesDefaultSession);

  final bool Function(WebViewModel model) sharesDefaultSession;
}

/// Pure-Dart unload policy engine.
///
/// Owns the three orthogonal "should this site be unloaded?" rules:
///
///   1. Webspace switch — under legacy isolation only, sites visible only in
///      the previous webspace are unloaded so the shared cookie jar stays
///      clean. Under container isolation, sites stay resident across
///      switches.
///   2. Proxy mismatch — on Android, the WebView proxy is process-global
///      (`inapp.ProxyController` last-write-wins). Activating a site with a
///      different effective proxy would silently re-route any other loaded
///      site's next request through the new proxy, defeating the user's
///      per-site proxy choice. Force-unload conflicting sites so they can't
///      leak.
///   3. LRU cap — bound the number of concurrently loaded webviews so memory
///      stays under control. Uses [SiteRetentionPriority] to decide eviction
///      order: lowest priority (highest enum index) first, LRU within each
///      tier.
class SiteUnloadEngine {
  /// The one way a loaded site is unloaded. Under the legacy engine the
  /// shared jar is captured first whatever the [reason] (ISO-002): the next
  /// activation empties it after attributing it to the loaded sites only, so
  /// a site unloaded without the capture loses what it set since its own
  /// activation.
  static Future<void> unload(
    SiteUnloadHost host,
    int index,
    UnloadReason reason,
  ) async {
    if (index < 0 || index >= host.models.length) return;
    final model = host.models[index];
    LogService.instance.log(
      LogTag.siteUnload,
      'Unloading site $index "${model.name}": ${reason.label}',
      level: reason.logLevel,
      sensitivity: LogSensitivity.sensitive,
    );
    if (reason.keepsNavState) await host.captureNavState(model);
    // A lower-indexed delete can shift the list across the capture.
    final at = host.models.indexOf(model);
    if (at < 0) return;
    final jar = host.sharedJar;
    if (jar == null) {
      model.disposeWebView();
      host.loadedIndices.remove(at);
    } else {
      await jar.unloadSiteForDomainSwitch(
        index: at,
        models: host.models,
        loadedIndices: host.loadedIndices,
      );
    }
    host.noteUnloaded(model, reason);
  }

  /// Every rule deciding which loaded sites go, and in what order, for
  /// [event]. Each rule reads the loaded set the rules before it leave.
  static ResidencyPlan plan(ResidencyHost host, ResidencyEvent event) {
    final models = host.models;
    final loaded = {...host.loadedIndices};
    final unloads = <({WebViewModel site, UnloadReason reason})>[];
    void unload(Iterable<int> indices, UnloadReason reason) {
      for (final i in indices.toList()) {
        if (i < 0 || i >= models.length || !loaded.remove(i)) continue;
        unloads.add((site: models[i], reason: reason));
      }
    }

    Set<int> proxyContenders(int target, {int? except}) =>
        indicesToUnloadForProxyMismatch(
          targetIndex: target,
          models: host.identities(except: except),
          loadedIndices: loaded,
          topology: host.proxyTopology,
        );
    Set<int> torDissenters(int anchor) => host.torAvailable
        ? indicesToUnloadForTorExitMismatch(
            targetIndex: anchor,
            models: host.identities(),
            loadedIndices: loaded,
          )
        : const {};
    Map<int, SiteLifecycleState> tiers() => {
          for (final i in loaded)
            if (i >= 0 && i < models.length) i: models[i].lifecycleState,
        };

    switch (event) {
      case Activating(:final target):
        // Under containers each site's jar is its own, so same-base-domain
        // sites coexist (CONT-003).
        if (host.sharedJar != null) {
          final conflict = SiteActivationEngine.findDomainConflict(
            targetIndex: target,
            models: models,
            loadedIndices: loaded,
          );
          unload([?conflict], UnloadReason.domainConflict);
        }
        unload(proxyContenders(target), UnloadReason.proxyMismatch);
        unload(torDissenters(target), UnloadReason.torExitMismatch);
        unload(
          indicesToEvictForLruCap(
            targetIndex: target,
            loadedIndices: loaded,
            maxLoadedSites: kMaxLoadedSites,
            priorityOf: host.priorityOf,
          ),
          UnloadReason.loadedSiteCap,
        );
        final cacheClears =
            SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
          loadedIndices: loaded,
          states: tiers(),
          maxResidentSites: kMaxResidentSites,
          priorityOf: host.priorityOf,
        );
        return ResidencyPlan(
          unloads: unloads,
          cacheClears: [for (final i in cacheClears) models[i]],
        );
      case MemoryPressure():
        final victim = SiteLifecyclePromotionEngine.pickPromotionTarget(
          loadedIndices: loaded,
          states: tiers(),
          priorityOf: host.priorityOf,
        );
        if (victim == null || victim >= models.length) return ResidencyPlan.none;
        final site = models[victim];
        return switch (
            SiteLifecyclePromotionEngine.nextState(site.lifecycleState)) {
          SiteLifecycleState.cacheCleared => ResidencyPlan(cacheClears: [site]),
          // The unload's state capture is what makes it savedForRestore.
          SiteLifecycleState.savedForRestore => ResidencyPlan(
              unloads: [(site: site, reason: UnloadReason.memoryPressure)]),
          SiteLifecycleState.resident || null => ResidencyPlan.none,
        };
      case WebspaceSwitched(:final previous, :final next):
        unload(
          indicesToUnloadOnWebspaceSwitch(
            useContainers: host.sharedJar == null,
            loadedIndices: loaded,
            previousWebspaceIndices: previous,
            newWebspaceIndices: next,
          ),
          UnloadReason.webspaceSwitch,
        );
      case TorExitSettled(:final order):
        final anchor = torExitAnchor(indices: order, models: host.identities());
        if (anchor != null) {
          unload(torDissenters(anchor), UnloadReason.torExitMismatch);
        }
      case NestedOpening(:final target):
        // The nested screen runs as [target] itself, whatever its slot shows.
        unload(proxyContenders(target, except: target),
            UnloadReason.proxyMismatch);
      case SlotIdentityChanged(:final slot):
        unload(proxyContenders(slot), UnloadReason.proxyMismatch);
    }
    return ResidencyPlan(unloads: unloads);
  }

  /// Runs [plan] through [unload]. A site no longer loaded when its turn
  /// comes is skipped. False when [isStale] turned true across an await, in
  /// which case the rest of the plan did not run.
  static Future<bool> apply(
    SiteUnloadHost host,
    ResidencyPlan plan, {
    required bool Function() isStale,
  }) async {
    for (final (:site, :reason) in plan.unloads) {
      final i = host.models.indexOf(site);
      if (i < 0 || !host.loadedIndices.contains(i)) continue;
      await unload(host, i, reason);
      if (isStale()) return false;
    }
    bool stillResident(WebViewModel site) {
      final i = host.models.indexOf(site);
      return i >= 0 &&
          host.loadedIndices.contains(i) &&
          site.lifecycleState == SiteLifecycleState.resident;
    }

    for (final site in plan.cacheClears) {
      if (!stillResident(site)) continue;
      LogTag.siteUnload.debug(
          'Clearing the cache of site "${site.name}"', sensitive: true);
      await site.clearWebViewCache();
      if (isStale()) return false;
      // A concurrent path may have promoted or unloaded it meanwhile.
      if (stillResident(site)) {
        site.lifecycleState = SiteLifecycleState.cacheCleared;
      }
    }
    return true;
  }

  /// Webspace-switch unload set. Returns the indices to dispose.
  static Set<int> indicesToUnloadOnWebspaceSwitch({
    required bool useContainers,
    required Set<int> loadedIndices,
    required Set<int> previousWebspaceIndices,
    required Set<int> newWebspaceIndices,
  }) {
    if (useContainers) return const <int>{};
    return WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
      loadedIndices: loadedIndices,
      previousWebspaceIndices: previousWebspaceIndices,
      newWebspaceIndices: newWebspaceIndices,
    );
  }

  /// Sites that must be unloaded because activating [targetIndex] would
  /// repoint a proxy they share out from under them: every mismatched
  /// sibling that contends for it under [topology], so at most one proxy is
  /// ever in force for a contending group.
  static Set<int> indicesToUnloadForProxyMismatch({
    required int targetIndex,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
    required ProxyTopology topology,
  }) {
    if (targetIndex < 0 || targetIndex >= models.length) return const <int>{};
    final target = models[targetIndex];
    final bool Function(WebViewModel model) contends;
    switch (topology) {
      case PerSessionProxy():
        return const <int>{};
      case ProcessGlobalProxy():
        contends = (_) => true;
      case RoutedProxy(:final sharesDefaultSession):
        if (!sharesDefaultSession(target)) return const <int>{};
        contends = sharesDefaultSession;
    }
    // With the site id, two Tor sites differ by their isolation tags, so
    // one rule never carries both and puts them on one circuit (TOR-003).
    final targetEffective =
        resolveEffectiveProxy(target.proxySettings, siteId: target.siteId);
    final result = <int>{};
    for (final i in loadedIndices) {
      if (i == targetIndex) continue;
      if (i < 0 || i >= models.length) continue;
      if (!contends(models[i])) continue;
      final effective = resolveEffectiveProxy(models[i].proxySettings,
          siteId: models[i].siteId);
      if (targetEffective.routeKey != effective.routeKey) {
        result.add(i);
      }
    }
    return result;
  }

  /// Sites that must be unloaded because activating [targetIndex] would
  /// repoint the process-global Tor `ExitNodes` out from under them.
  ///
  /// Same shape as [indicesToUnloadForProxyMismatch] and for the same
  /// reason: `ExitNodes`/`StrictNodes` are global client options in
  /// `tor(1)` — unlike the isolation flags they cannot be scoped to a
  /// `SocksPort`, so one tor cannot serve two countries at once, and iOS
  /// forbids a second process to run a second tor in. Two loaded sites
  /// pinned to different countries would therefore share whichever pin was
  /// written last, which is precisely the silent mis-routing the
  /// fail-closed posture exists to prevent (TOR-014).
  ///
  /// Any difference conflicts, *including* unpinned against pinned. An
  /// unpinned Tor site is not indifferent: leaving it loaded beside a `{de}`
  /// site would route it through Germany too, because there is only one
  /// `ExitNodes` — a country the user never chose for it, silently, on
  /// account of an unrelated site. "No pin" therefore reads as "must be
  /// unrestricted" and is a constraint like any other.
  ///
  /// Sites that do not route through Tor at all are untouched: `ExitNodes`
  /// says nothing about where their traffic goes.
  static Set<int> indicesToUnloadForTorExitMismatch({
    required int targetIndex,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) {
    if (targetIndex < 0 || targetIndex >= models.length) return const <int>{};
    final target = _torExitPin(models[targetIndex]);
    if (target == null) return const <int>{};
    final result = <int>{};
    for (final i in loadedIndices) {
      if (i == targetIndex) continue;
      if (i < 0 || i >= models.length) continue;
      final other = _torExitPin(models[i]);
      if (other == null) continue;
      if (target != other) result.add(i);
    }
    return result;
  }

  /// The `ExitNodes` value that should be in force while [indices] are the
  /// loaded sites, or null when nothing among them wants a pinned exit.
  ///
  /// Well-defined only because [indicesToUnloadForTorExitMismatch] has
  /// already evicted every site that disagrees: the loaded Tor sites share
  /// one constraint by construction, so the first one found answers for all
  /// of them. Pass the site being activated first, since it is the one
  /// whose constraint the eviction was computed against.
  ///
  /// Derived from the loaded set rather than from a single site so that
  /// clearing a pin in settings, or unloading the site that held it, drops
  /// the pin instead of leaving it applied to whatever loads next.
  static String? torExitNodesFor({
    required Iterable<int> indices,
    required List<WebViewModel> models,
  }) {
    for (final i in indices) {
      if (i < 0 || i >= models.length) continue;
      final pin = _torExitPin(models[i]);
      if (pin == null) continue;
      return pin == _torUnpinned ? null : pin;
    }
    return null;
  }

  /// The site whose exit constraint wins among [indices], in their order:
  /// the first that routes through Tor. Null when none does.
  ///
  /// [torExitNodesFor] reads the pin off the same site, so evicting what
  /// [indicesToUnloadForTorExitMismatch] names against it leaves every
  /// loaded Tor site agreeing with the pin that goes into force.
  static int? torExitAnchor({
    required Iterable<int> indices,
    required List<WebViewModel> models,
  }) {
    for (final i in indices) {
      if (i < 0 || i >= models.length) continue;
      if (_torExitPin(models[i]) != null) return i;
    }
    return null;
  }

  /// Whether the Tor sites among [indices] are all archive-tier.
  ///
  /// Such a pin may use a GeoIP table already on the device but must not
  /// download one (ARCH-006): the file would be a trace outside the
  /// archive's keyspace, and with no app-tier site pinned, its presence
  /// would say an archived site was. False when no Tor site is among them.
  static bool torExitPinIsArchiveOnly({
    required Iterable<int> indices,
    required List<WebViewModel> models,
  }) {
    var any = false;
    for (final i in indices) {
      if (i < 0 || i >= models.length) continue;
      if (_torExitPin(models[i]) == null) continue;
      if (!models[i].isArchiveTier) return false;
      any = true;
    }
    return any;
  }

  /// Stands in for a Tor site that pins no country. Distinct from null,
  /// which means the site does not use Tor and so is indifferent to
  /// `ExitNodes` entirely. Not a legal `ExitNodes` value, so it cannot
  /// collide with a real pin.
  static const String _torUnpinned = '<unpinned>';

  /// The site's effective exit-country constraint, or null when it has
  /// none because it does not route through Tor.
  ///
  /// Read off the *effective* settings, so a site on DEFAULT inherits the
  /// global proxy's country, and a country left over on a site since
  /// switched to SOCKS5 constrains nothing.
  static String? torExitConstraint(WebViewModel model) => _torExitPin(model);

  static String? _torExitPin(WebViewModel model) {
    final effective =
        resolveEffectiveProxy(model.proxySettings, siteId: model.siteId);
    if (effective.type != ProxyType.TOR) return null;
    return effective.exitNodesValue ?? _torUnpinned;
  }

  /// LRU eviction set. Returns the indices to evict (oldest first) so that
  /// [loadedIndices] plus [targetIndex] fits within [maxLoadedSites].
  static List<int> indicesToEvictForLruCap({
    required int targetIndex,
    required Set<int> loadedIndices,
    required int maxLoadedSites,
    required SiteRetentionResolver priorityOf,
  }) {
    final projected = loadedIndices.contains(targetIndex)
        ? loadedIndices.length
        : loadedIndices.length + 1;
    final overflow = projected - maxLoadedSites;
    if (overflow <= 0) return const [];
    return evictionOrder(
      loadedIndices.where((i) => i != targetIndex),
      priorityOf,
    ).take(overflow).toList();
  }
}
