// The three capture shims as buildCaptureShim (lib/services/capture_shim.dart)
// builds them, from each CaptureKind's handler names and published device.

const { pageJs } = require('./page_js');

module.exports = {
  CAMERA: pageJs('camera_stream', {
    shimGroup: 'camera_stream',
    deviceLabel: 'Integrated Camera',
    requestHandler: 'webCameraRequest',
    modeHandler: 'webCameraMode',
    deviceKind: 'videoinput',
  }),
  MICROPHONE: pageJs('microphone_stream', {
    shimGroup: 'microphone_stream',
    deviceLabel: 'Microphone Array',
    requestHandler: 'webMicrophoneRequest',
    modeHandler: 'webMicrophoneMode',
    deviceKind: 'audioinput',
  }),
  SCREEN_SHARE: pageJs('screen_share', {
    shimGroup: 'screen_share',
    deviceLabel: 'Screen',
    requestHandler: 'webScreenShareRequest',
  }),
};
