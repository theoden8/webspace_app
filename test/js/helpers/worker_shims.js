// The worker installer as buildWorkerShimScript (lib/services/worker_shim.dart)
// composes it: the page's scoped shims, then worker_payload.js, as the payload
// every worker loads first.

const { pageJs } = require('./page_js');
const { FX_ANDROID } = require('./ua_identities');
const { location } = require('./location_configs');

// What every worker loads first: the page's shims, then worker_payload.js.
function workerPayload(bodies) {
  return `${bodies.map((s) => s.trim()).join('\n')}\n${pageJs('worker_payload')}`;
}

function workerShim(bodies) {
  return pageJs('worker_shim', { payload: workerPayload(bodies) });
}

// The realistic bundle a spoofed site gets: anti-fingerprinting, identity,
// timezone and language.
const COMBINED_BODIES = [
  pageJs('anti_fingerprinting', { seed: 'alpha-fixture-seed', letterbox: false }),
  FX_ANDROID,
  location({ timezone: 'UTC', webRtc: 'off' }),
  pageJs('language', { language: 'en' }),
];

module.exports = {
  workerShim,
  workerPayload,
  // Keeps the installer's own behaviour readable in review.
  INSTALLER_LANGUAGE_ONLY: workerShim([pageJs('language', { language: 'en' })]),
  INSTALLER_COMBINED: workerShim(COMBINED_BODIES),
  COMBINED_PAYLOAD: workerPayload(COMBINED_BODIES),
};
