import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/page_js.dart';

/// The page shims whose values a worker can read too, built once so the page
/// and its workers report the same thing. Null where the site spoofs nothing.
typedef ScopedShims = ({
  String? webGl,
  String? antiFingerprinting,
  String? identity,
  String location,
  String? timezone,
  String? language,
});

/// What [buildWorkerShimScript] propagates from [s], in page-injection order.
/// The location shim goes only with a timezone: its geolocation and WebRTC
/// halves are window-only, so without one it would wrap a site's workers for
/// nothing (WORK-006). Window-only shims (desktop mode, viewport, zoom,
/// notifications) are not in [ScopedShims] at all.
List<String> workerScopeBodies(ScopedShims s) => [
      ?s.webGl,
      ?s.antiFingerprinting,
      ?s.identity,
      if (LocationSpoofService.affectsWorkerScope(s.timezone)) s.location,
      ?s.language,
    ];

/// The page-side installer (lib/js/worker_shim.js) that patches `Worker` /
/// `SharedWorker` to preload [shimSources] into every worker global scope.
///
/// [shimSources] are the same shim bodies injected into the document, in
/// injection order. Returns `null` when there is nothing to propagate, so a
/// site with no active spoofing keeps the stock constructors (and therefore
/// cannot be broken by the blob indirection).
String? buildWorkerShimScript(List<String> shimSources) {
  final active = shimSources
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (active.isEmpty) return null;
  return PageJs.workerShim.withConfig({
    'payload': '${active.join('\n')}\n${PageJs.workerPayload.script}',
  });
}
