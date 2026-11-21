/// When a site's onion check runs, and what its answer does to what the site
/// saved (ONION-003, ONION-007, ONION-008). Pure: no Flutter, no I/O.
library;

import 'package:webspace/services/onion_location.dart';

/// How long an onion address in use goes before it is checked again.
const Duration kOnionRecheck = Duration(days: 30);

/// Whether the first page a site loads in a run, [pageUrl], is a reason to
/// check it: never off Tor (ONION-007); always on a clearnet page, which is
/// already going through an exit; on the onion only when [saved] was last
/// checked more than [kOnionRecheck] ago (ONION-008). The caller checks a
/// site at most once a run.
bool onionCheckDue(
  SiteOnion? saved, {
  required bool tor,
  required String pageUrl,
  required DateTime now,
}) {
  if (!tor) return false;
  if (saved == null || !saved.endpoint.isOnion(pageUrl)) return true;
  return now.difference(saved.checked) > kOnionRecheck;
}

/// What a check's answer does to what the site saved.
sealed class OnionLearning {
  const OnionLearning();
}

/// Nothing changes: the check failed, or nothing was learned before or now.
final class OnionKept extends OnionLearning {
  const OnionKept();
}

/// The site announces nothing now: the address and its answer go
/// (ONION-003).
final class OnionForgotten extends OnionLearning {
  const OnionForgotten();
}

/// The site announces [onion]'s address: the same one, checked again, or a
/// new one. [asks] when the user has not answered for it yet, which a
/// changed address never has (ONION-003).
final class OnionLearned extends OnionLearning {
  const OnionLearned(this.onion);
  final SiteOnion onion;

  bool get asks => onion.answer == null;
}

/// What [found] does to [saved], read after the check's await so an answer
/// given meanwhile is kept. A new address keeps the fallback chosen for the
/// old one (ONION-009).
OnionLearning learnFrom(
  OnionCheck found, {
  required SiteOnion? saved,
  required DateTime now,
}) => switch (found) {
  OnionCheckFailed() => const OnionKept(),
  NothingAnnounced() =>
    saved == null ? const OnionKept() : const OnionForgotten(),
  OnionAnnounced(:final endpoint) => OnionLearned(SiteOnion(
      endpoint: endpoint,
      checked: now,
      answer: saved?.endpoint == endpoint ? saved?.answer : null,
      fallback: saved?.fallback ?? OnionFallback.none,
    )),
};
