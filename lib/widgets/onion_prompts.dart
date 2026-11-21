import 'package:flutter/material.dart';
import 'package:webspace/controllers/onion_location_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/onion_choice.dart';
import 'package:webspace/widgets/confirm_dialog.dart';

/// [OnionPrompts] as dialogs over the page that owns [context].
class DialogOnionPrompts implements OnionPrompts {
  const DialogOnionPrompts(this.context);

  final BuildContext context;

  @override
  Future<OnionAnswer?> offerOnion({required String site, required String onion}) {
    final loc = AppLocalizations.of(context);
    return choose<OnionAnswer>(
      context,
      title: loc.siteNetworkOnion,
      body: loc.onionOfferBody(site, onion),
      options: [
        (OnionAnswer.declined, loc.onionOfferDecline),
        (OnionAnswer.accepted, loc.onionOfferUse),
      ],
    );
  }
}
