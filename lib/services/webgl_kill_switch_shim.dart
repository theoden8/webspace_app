// JavaScript that disables every entry-point JS has into WebGL context
// creation, so chromium never enters its WebGL-blocklist code path —
// the suspect for a dangling-raw_ptr SIGTRAP at
// `partition_alloc_support.cc:770` on the Android System WebView build
// our crash logs come from. Injected at DOCUMENT_START into every frame of
// a tracking-protected site, on every platform (see
// WebViewFactory._buildPageScripts), and into every worker of it, where a
// live OffscreenCanvas WebGL context would otherwise contradict the page.
//
// Coverage:
//   - HTMLCanvasElement.prototype.getContext('webgl' | 'webgl2' |
//     'experimental-webgl' | 'experimental-webgl2') → null
//   - OffscreenCanvas.prototype.getContext same treatment
//   - window.WebGLRenderingContext / WebGL2RenderingContext deleted so
//     `typeof WebGLRenderingContext === 'undefined'` feature detection
//     short-circuits before getContext is even attempted
//   - navigator.gpu, the GPU* constructors and getContext('webgpu'):
//     WebGPU's requestAdapter() reports vendor, architecture, device and a
//     limits table, a sharper GPU fingerprint than WebGL ever exposed, so
//     removing WebGL and leaving it is an oversight rather than a posture
const String webGlKillSwitchScript = r'''
(function() {
  var GL_TYPES = {
    'webgl': 1, 'webgl2': 1,
    'experimental-webgl': 1, 'experimental-webgl2': 1,
    // The canvas is a second route to WebGPU: deleting navigator.gpu alone
    // leaves getContext('webgpu') handing back a live GPUCanvasContext.
    'webgpu': 1
  };
  function patchGetContext(proto) {
    if (!proto || !proto.getContext) return;
    var orig = proto.getContext;
    proto.getContext = function(type) {
      if (typeof type === 'string' && GL_TYPES[type.toLowerCase()]) {
        return null;
      }
      return orig.apply(this, arguments);
    };
  }
  try { patchGetContext(HTMLCanvasElement.prototype); } catch (_) {}
  try {
    if (typeof OffscreenCanvas !== 'undefined') {
      patchGetContext(OffscreenCanvas.prototype);
    }
  } catch (_) {}
  try { delete globalThis.WebGLRenderingContext; } catch (_) {}
  try { delete globalThis.WebGL2RenderingContext; } catch (_) {}
  var GPU_GONE = [
    'GPU', 'GPUAdapter', 'GPUDevice', 'GPUCanvasContext', 'GPUAdapterInfo'
  ];
  for (var i = 0; i < GPU_GONE.length; i++) {
    try { delete globalThis[GPU_GONE[i]]; } catch (_) {}
  }
  try {
    var NavProto = (typeof navigator !== 'undefined' && navigator)
      ? Object.getPrototypeOf(navigator) : null;
    if (NavProto) { delete NavProto.gpu; }
  } catch (_) {}
})();
''';
