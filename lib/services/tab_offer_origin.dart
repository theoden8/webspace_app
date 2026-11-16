/// The page that requested a background tab. A confirmation after an await
/// belongs on that page only while the same site and tab remain visible.
final class TabOfferOrigin {
  const TabOfferOrigin({
    required this.site,
    required this.tab,
    required this.activationVersion,
  });

  final Object? site;
  final Object? tab;
  final int activationVersion;

  bool stillVisible({
    required Object? shownSite,
    required Object? shownTab,
    required Object offerSite,
    required int currentActivationVersion,
  }) =>
      identical(site, shownSite) &&
      identical(site, offerSite) &&
      tab == shownTab &&
      activationVersion == currentActivationVersion;
}
