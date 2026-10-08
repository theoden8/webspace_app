// The identity configs the app derives for four UAs, one per engine and form
// factor; test/user_agent_identity_shim_test.dart pins the same values against
// uaIdentityFor.

const { pageJs } = require('./page_js');

const identity = (config) => pageJs('ua_identity', config);

module.exports = {
  // Firefox-Android (Gecko mobile): vendor "", oscpu/buildID set, platform
  // "Linux armv8l".
  FX_ANDROID: identity({
    vendor: '', productSub: '20100101', oscpu: 'Linux armv8l',
    buildID: '20181001000000', platform: 'Linux armv8l', removeUserAgentData: true,
  }),
  // Firefox on Linux (Gecko desktop).
  FX_LINUX_DESKTOP: identity({
    vendor: '', productSub: '20100101', oscpu: 'Linux x86_64',
    buildID: '20181001000000', platform: 'Linux x86_64', removeUserAgentData: false,
  }),
  // FxiOS (WebKit mobile): Apple vendor, no oscpu/buildID, userAgentData
  // removed.
  FXIOS: identity({
    vendor: 'Apple Computer, Inc.', productSub: '20030107', oscpu: null,
    buildID: null, platform: 'iPhone', removeUserAgentData: true,
  }),
  // Chrome-Android (Blink mobile): Google vendor, userAgentData kept.
  CHROME_ANDROID: identity({
    vendor: 'Google Inc.', productSub: '20030107', oscpu: null,
    buildID: null, platform: 'Linux armv8l', removeUserAgentData: false,
  }),
};
