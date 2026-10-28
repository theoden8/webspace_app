import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/block_stats_engine.dart';

/// How a protection report category is named and drawn wherever it shows.
extension BlockCategoryLabel on BlockCategory {
  String label(AppLocalizations loc) => switch (this) {
        BlockCategory.filterList => loc.blockStatsCategoryFilterList,
        BlockCategory.dnsBlocklist => loc.blockStatsCategoryDns,
        BlockCategory.trackingParam => loc.blockStatsCategoryParam,
        BlockCategory.localCdn => loc.blockStatsCategoryCdn,
      };

  IconData get icon => switch (this) {
        BlockCategory.filterList => Icons.block,
        BlockCategory.dnsBlocklist => Icons.dns_outlined,
        BlockCategory.trackingParam => Icons.link_off,
        BlockCategory.localCdn => Icons.cloud_off_outlined,
      };
}
