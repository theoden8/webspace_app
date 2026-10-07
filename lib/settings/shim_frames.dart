/// Which frames a page shim reaches.
///
/// No default: the plugin's own is main-frame-only (WKUserScript's), so a
/// shim that forgot to say looked exactly like one that meant it, and a
/// cross-origin iframe ran unpatched.
enum ShimFrames { all, top }
