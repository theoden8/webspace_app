// Behavioural tests for the WebGL/WebGPU kill switch
// (lib/services/webgl_kill_switch_shim.dart), which rides the per-site
// tracking protection toggle.
//
// jsdom ships none of these constructors, so every assertion here would pass
// against an empty script if it only read the end state. Each test seeds the
// surface it is about first, which is what lets it fail.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const SHIM = 'webgl_kill_switch/shim.js';

function seedGpuSurface(window) {
  class WebGLRenderingContext {}
  class WebGL2RenderingContext {}
  class GPU { requestAdapter() { return Promise.resolve({}); } }
  class GPUAdapter {}
  class GPUDevice {}
  class GPUCanvasContext {}
  class GPUAdapterInfo {}
  Object.assign(window, {
    WebGLRenderingContext, WebGL2RenderingContext,
    GPU, GPUAdapter, GPUDevice, GPUCanvasContext, GPUAdapterInfo,
  });
  Object.defineProperty(Object.getPrototypeOf(window.navigator), 'gpu', {
    configurable: true, enumerable: true, get: () => new GPU(),
  });
  window.HTMLCanvasElement.prototype.getContext = function (type) {
    return { __type: type };
  };
}

function shimmed() {
  const dom = makeDom();
  seedGpuSurface(dom.window);
  runInDom(dom, readFixture(SHIM));
  return dom;
}

test('every WebGL context type returns null from getContext', () => {
  const dom = shimmed();
  const canvas = dom.window.document.createElement('canvas');
  for (const type of
      ['webgl', 'webgl2', 'experimental-webgl', 'experimental-webgl2']) {
    assert.equal(canvas.getContext(type), null, type);
  }
});

test("getContext('webgpu') returns null too", () => {
  // Deleting navigator.gpu alone leaves the canvas handing back a live
  // GPUCanvasContext.
  const dom = shimmed();
  const canvas = dom.window.document.createElement('canvas');
  assert.equal(canvas.getContext('webgpu'), null);
  assert.equal(canvas.getContext('WebGPU'), null, 'type match is case-insensitive');
});

test('non-GPU context types still fall through', () => {
  const dom = shimmed();
  const canvas = dom.window.document.createElement('canvas');
  assert.equal(canvas.getContext('2d').__type, '2d');
});

test('the WebGL and WebGPU constructors are gone', () => {
  const dom = shimmed();
  for (const name of [
    'WebGLRenderingContext', 'WebGL2RenderingContext',
    'GPU', 'GPUAdapter', 'GPUDevice', 'GPUCanvasContext', 'GPUAdapterInfo',
  ]) {
    assert.equal(dom.window.eval(`typeof ${name}`), 'undefined', name);
  }
});

test('navigator.gpu is gone', () => {
  const dom = shimmed();
  assert.equal(dom.window.navigator.gpu, undefined);
  assert.equal(dom.window.eval("'gpu' in navigator"), false);
});
