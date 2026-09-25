/// The sequence around opening a nested screen for an existing site: an
/// inbound cross-domain open (LIR-011) or an outbound routed one (LIR-015).
///
/// Extracted from `_WebSpacePageState._executeOpenNested` so the ordering
/// rules can run headlessly against a fake that models the process-global
/// proxy. The host does the IO; this decides what runs, in which order, and
/// when to stop.
library;

/// What the sequence needs from the app. [T] is the host's site handle, held
/// across the awaits rather than an index, because the list can shift under
/// them.
abstract class NestedOpenHost<T> {
  bool get mounted;

  /// Android without router mode, and Linux: one proxy for the whole process,
  /// which only an activation flips (PROXY-008).
  bool get proxyIsProcessGlobal;

  /// Where [site] sits in the list now, or -1 when it is gone.
  int indexOf(T site);

  /// The active site's index, or null on the webspace list.
  int? get currentIndex;

  /// WEBSPACE-012: switch to "All" when the current webspace hides [target].
  Future<void> switchWebspaceFor(T target);

  /// Loaded sites whose proxy differs from [target]'s. Only read when
  /// [proxyIsProcessGlobal].
  Set<int> mismatchedWith(T target);

  Future<void> unload(int index);

  /// Throws when the proxy cannot be applied.
  Future<void> applyProxyOf(T target);

  void reportProxyFailure(Object error);

  /// Completes when the screen pops.
  Future<void> launchNested(T target, String url);

  /// The full activation path: the site's proxy, then its rebuild.
  Future<void> activate(int index);
}

enum NestedOpenOutcome {
  /// The screen opened and was closed again.
  opened,

  /// The proxy could not be applied, so nothing opened (SEC-004).
  proxyRefused,

  /// The widget went away mid-sequence.
  abandoned,
}

class NestedOpenEngine {
  NestedOpenEngine._();

  /// Open [target]'s nested screen at [url].
  ///
  /// With [source] set, the screen opens over the site the link came from
  /// (LIR-015): the webspace is left alone, and when the proxy sequence
  /// unloaded the source, the source comes back through [NestedOpenHost.activate]
  /// once the screen pops or the open is refused. Activation applies the
  /// source's proxy before rebuilding it, so the source is never rebuilt
  /// under the destination's proxy. It comes back only while it is still the
  /// current site: a user who moved on while the screen was up is not pulled
  /// back.
  static Future<NestedOpenOutcome> run<T>(
    NestedOpenHost<T> host, {
    required T target,
    required String url,
    T? source,
  }) async {
    if (source == null) {
      await host.switchWebspaceFor(target);
      if (!host.mounted) return NestedOpenOutcome.abandoned;
    }
    var sourceUnloaded = false;
    Future<void> returnToSource() async {
      if (!sourceUnloaded || source == null || !host.mounted) return;
      final index = host.indexOf(source);
      if (index < 0 || index != host.currentIndex) return;
      await host.activate(index);
    }

    if (host.proxyIsProcessGlobal) {
      final mismatch = host.mismatchedWith(target);
      sourceUnloaded = source != null && mismatch.contains(host.indexOf(source));
      for (final index in mismatch) {
        await host.unload(index);
        if (!host.mounted) return NestedOpenOutcome.abandoned;
      }
      try {
        await host.applyProxyOf(target);
      } catch (e) {
        host.reportProxyFailure(e);
        if (!host.mounted) return NestedOpenOutcome.abandoned;
        await returnToSource();
        return NestedOpenOutcome.proxyRefused;
      }
      if (!host.mounted) return NestedOpenOutcome.abandoned;
    }
    await host.launchNested(target, url);
    await returnToSource();
    return NestedOpenOutcome.opened;
  }
}
