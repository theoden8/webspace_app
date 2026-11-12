import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/webview_tab_binding.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';

/// A site as the residency and jar engines hold it: what they read of it and
/// the few acts they ask of it, so a service never reaches the model's type.
abstract interface class EngineSite implements SiteKeyed {
  @override
  SiteId get siteId;

  String get name;

  /// The site's memory tier, written only through [tierCell].
  TierBox get tier;

  /// Where the site starts, and where its active tab is now.
  String get initUrl;
  String get currentUrl;

  bool get effectiveIncognito;
  bool get isArchiveTier;
  UserProxySettings get proxySettings;

  /// The site's share of the shared jar, kept while it is not loaded.
  List<Cookie> get cookies;
  set cookies(List<Cookie> value);
  bool isCookieBlocked(String name, {required String? domain});

  /// The site its active tab runs as (LIR-018), and each tab's (CONT-012).
  EngineSite get runningIdentity;
  TabHosts<SiteId> get tabHostIds;

  /// Which tab's history the site's webview shows (TAB-003).
  WebViewTabBinding get tabBinding;

  /// Lets go of the site's webview, in [commit].
  void disposeWebView({required Commit commit});
  Future<void> clearWebViewCache();
}

/// Where code holding sites by id finds the site it acts on (CONT-012).
abstract interface class SitesById {
  EngineSite siteOf(SiteId id);
}

/// A site's memory tier, the model's `tier`: read by anyone, written only
/// by [tierCell] in a [Commit].
final class TierBox {
  SiteLifecycleState _value = SiteLifecycleState.resident;

  SiteLifecycleState get value => _value;
}

/// The model's `tier`, written only through a [Commit].
final tierCell = SharedAt<EngineSite, SiteLifecycleState>(
  ModelVar.tier,
  read: (s) => s.tier._value,
  write: (s, {required to}) => s.tier._value = to,
);
