import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/services/page_js.dart';

const kLinkNewTabHandler = 'wsLinkNewTab';

/// The script by which a link clicked with [convention]'s new-tab modifier,
/// or with the middle button, asks for a new tab (TAB-029).
String linkNewTabClickScript(KeyConvention convention) =>
    PageJs.linkNewTabClick.withConfig({
      'handler': kLinkNewTabHandler,
      'modifier': convention.newTabClickKey,
    });

/// Answers [linkNewTabClickScript] in [view]: the top document's http(s) link
/// goes to [open]. A subframe's word is not taken, as the script runs only
/// in the top document.
void answerLinkNewTabClicks(
  inapp.InAppWebViewController view, {
  required void Function(String url) open,
}) {
  view.addJavaScriptHandler(
    handlerName: kLinkNewTabHandler,
    callback: (inapp.JavaScriptHandlerFunctionData call) {
      if (!call.isMainFrame) return null;
      if (linkOfNewTabClick(call.args) case final url?) open(url);
      return null;
    },
  );
}

/// The http(s) link a click's report names, or null.
String? linkOfNewTabClick(List<dynamic> args) {
  if (args case [final String href]) {
    final uri = Uri.tryParse(href);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      return href;
    }
  }
  return null;
}
