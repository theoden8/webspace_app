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
  try { delete window.WebGLRenderingContext; } catch (_) {}
  try { delete window.WebGL2RenderingContext; } catch (_) {}
  var GPU_GONE = [
    'GPU', 'GPUAdapter', 'GPUDevice', 'GPUCanvasContext', 'GPUAdapterInfo'
  ];
  for (var i = 0; i < GPU_GONE.length; i++) {
    try { delete window[GPU_GONE[i]]; } catch (_) {}
  }
  try {
    var NavProto = (typeof navigator !== 'undefined' && navigator)
      ? Object.getPrototypeOf(navigator) : null;
    if (NavProto) { delete NavProto.gpu; }
  } catch (_) {}
})();
