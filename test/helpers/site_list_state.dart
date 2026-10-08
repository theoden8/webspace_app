import 'package:webspace/services/site_lifecycle_engine.dart';
import 'package:webspace/web_view_model.dart';

/// The positional site list `_WebSpacePageState` keeps. Deletion applies the
/// production [SiteLifecycleEngine] patch so a harness cannot drift from it.
mixin SiteListState {
  final List<WebViewModel> sites = [];
  final Set<int> loadedIndices = {};
  int? currentIndex;

  void removeSiteAt(int index) {
    final patch = SiteLifecycleEngine.computeDeletionPatch(
      deletedIndex: index,
      siteCountBeforeRemoval: sites.length,
      loadedIndices: loadedIndices,
      webspaces: const [],
      currentIndex: currentIndex,
    );
    sites.removeAt(index);
    loadedIndices
      ..clear()
      ..addAll(patch.newLoadedIndices);
    currentIndex = patch.newCurrentIndex;
  }
}
