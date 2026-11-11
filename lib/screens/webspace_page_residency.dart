part of 'webspace_page.dart';

/// What the page answers for the residency engine.
class _ResidencyHost implements ResidencyHost {
  const _ResidencyHost(this.state);

  final _WebSpacePageState state;

  @override
  ResidencyCaps get caps => kResidencyCaps;

  @override
  List<WebViewModel> get models => state._sites.models;

  @override
  RuntimeVars<SiteId> get vars => state._sites.vars;

  @override
  WebViewModel siteOf(SiteId id) => state._sites.siteOf(id);

  @override
  Isolation get isolation => state._sites.isolation;

  @override
  NavCapture? beginNavCapture(WebViewModel model) =>
      state._activation.beginNavCapture(model);

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) =>
      state._background.noteUnloaded(model, reason: reason.label);

  @override
  SlotIdentities identities() => state._sites.slotIdentities();

  @override
  SiteRetentionPriority priorityOf(int index) =>
      state._sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => state._network.topology;

  @override
  bool get torAvailable => TorService.instance.isAvailable;
}
