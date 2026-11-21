/// What the user answered about a site's announced onion address
/// (ONION-003).
enum OnionAnswer { accepted, declined }

/// What a load the move sent to the onion origin does when it fails, is
/// rejected by TLS or says nothing (ONION-006): stay on the failure, or load
/// the clearnet URL it moved, through an exit. The user chooses; staying is
/// the default (ONION-009).
enum OnionFallback { none, clearnet }
