// Whether this document is one of the pages a user script's header names
// (US-009). Dart compiled the header's patterns into anchored regular
// expressions (lib/services/userscript_header.dart), so this decides
// nothing itself: the URL runs the script when an include names it, or
// the header names none (`include` is null), and no exclude names it.
//
// A pattern the page's engine will not compile names no page: a user's
// /regex/ can use syntax Dart reads and this engine does not.
const url = location.href;
const names = (pattern) => {
  try {
    return new RegExp(pattern.source, pattern.flags).test(url);
  } catch (e) {
    if (e instanceof SyntaxError) return false;
    throw e;
  }
};
return (CONFIG.include === null || CONFIG.include.some(names)) &&
  !CONFIG.exclude.some(names);
