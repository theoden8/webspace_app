/// Current Mobile Safari on iPhone. Since iOS 26 Safari freezes the OS token
/// (`18_6` at 26.0, `18_7` from 26.2) and carries its own version in
/// `Version/`, so the two no longer agree.
const String mobileSafariIphoneUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 '
    'Mobile/15E148 Safari/604.1';

/// Current Mobile Safari on iPad, as sent when the mobile site is requested
/// (the iPad default is the desktop `Macintosh` UA).
const String mobileSafariIpadUserAgent =
    'Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 '
    'Mobile/15E148 Safari/604.1';
