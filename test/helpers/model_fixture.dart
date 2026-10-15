import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';

/// A site's tabs and tier as a test sets them before the steps under test
/// run: the model writes them only in a [Commit], and a test's is a
/// fixture's.
extension ModelFixture on WebViewModel {
  void setTabs(List<SiteTab> to) =>
      WebViewModel.tabsCell.write(at: this, to: to, commit: const Commit.fixture());

  void setActiveTab(TabId to) => WebViewModel.activeTabCell
      .write(at: this, to: to, commit: const Commit.fixture());

  void setTier(SiteLifecycleState to) =>
      WebViewModel.tierCell.write(at: this, to: to, commit: const Commit.fixture());
}

/// The lists as a test sets them up, or changes them where a test stands in
/// for the page: [SiteRuntime.apply] and [SiteRuntime.retired] with a
/// fixture's commit.
extension SiteRuntimeFixture on SiteRuntime {
  void applied(SiteSetChange change) =>
      apply(change, commit: const Commit.fixture());

  bool retiredInTest(WebViewModel site) =>
      retired(site, commit: const Commit.fixture());
}

/// A change to the lists a test's host lands as it is told, with nothing
/// before or after it: the fake of a [SiteSetStage].
final class AppliedStage implements SiteSetStage {
  AppliedStage(this._land);

  final void Function(Commit commit) _land;

  @override
  Future<void> prepare() async {}

  @override
  void land({required Commit commit}) => _land(commit);

  @override
  Future<void> follow() async {}
}
