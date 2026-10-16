import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/web_view_model.dart';
import 'model_fixture.dart';

/// The page's site list for a harness, kept by the production [SiteRuntime]
/// so a harness cannot drift from it. Rows are read off it for assertions.
mixin SiteListState {
  final SiteRuntime runtime = SiteRuntime();

  List<WebViewModel> get sites => runtime.models;
  RuntimeVars<WebViewModel> get vars => runtime.vars;
  Set<int> get loadedIndices => runtime.loadedRows;
  int? get currentIndex => runtime.current;

  /// [site] on screen, and last in the loaded order, as an activation's
  /// commit leaves it.
  void show(WebViewModel site) => runtime.seed(
    loaded: [...runtime.loaded.where((m) => !identical(m, site)), site],
    shown: site,
  );

  void removeSiteAt(int index) => runtime.applied(SiteRemoved(sites[index]));
}
