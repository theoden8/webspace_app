import 'package:flutter/material.dart';
import 'package:webspace/controllers/link_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/dispatch_picker_sheet.dart';
import 'package:webspace/widgets/web_search_sheet.dart';

/// [LinkPrompts] as sheets and dialogs over the page that owns [context].
class DialogLinkPrompts implements LinkPrompts {
  const DialogLinkPrompts(this.context);

  final BuildContext context;

  @override
  Future<WebSearchRequest?> webSearch(WebSearchAsk ask) =>
      showModalBottomSheet<WebSearchRequest>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => WebSearchSheet(
          identity: ask.identity,
          candidates: ask.candidates,
          declared: ask.declared,
          declaredDefault: ask.declaredDefault,
          appDefault: ask.appDefault,
          canAddSites: ask.canAddSites,
          initialQuery: ask.initialQuery,
          containerColors: ask.containerColors,
        ),
      );

  @override
  Future<DispatchChoice?> pickSite(SitePick pick) =>
      showModalBottomSheet<DispatchChoice>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => DispatchPickerSheet(
          url: pick.url,
          winners: pick.winners,
          otherSites: pick.otherSites,
          canBind: pick.canBind,
          canCreate: pick.canCreate,
          claimDomains: pick.claimDomains,
          outboundSourceName: pick.outboundSourceName,
        ),
      );

  @override
  Future<bool> reviewSharedHtml({
    required String title,
    required String url,
  }) {
    final loc = AppLocalizations.of(context);
    return confirm(
      context,
      title: loc.homeQrReviewTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) Text(loc.homeQrReviewName(title)),
          Text(loc.homeQrReviewUrl(url)),
        ],
      ),
      confirmLabel: loc.homeCreateAction,
      destructive: false,
    );
  }
}
