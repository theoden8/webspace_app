import 'package:webspace/services/link_routing_service.dart';

const bool shimHasLinks = true;

/// The inner URL this release unwrapped, null when it rejected the link, or
/// `!throws` when parsing raised instead of rejecting.
String? shimParseLink(String raw) {
  try {
    return LinkRoutingService.parseWebspaceUri(Uri.parse(raw))?.toString();
  } on FormatException {
    return '!throws';
  }
}
