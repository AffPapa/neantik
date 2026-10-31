import assert from 'node:assert/strict';

export const COHORTS = Object.freeze([{seed: 11, id: 'macbook-air-m1'}, {seed: 13, id: 'macbook-air-m2'},
  {seed: 16, id: 'macbook-air-m3'}, {seed: 19, id: 'macbook-air-m4'}]);

export function verifyProbe(data, tuple) {
  assert.equal(data.schemaVersion, 1); assert.deepEqual(data.errors, []);
  assert.deepEqual(data.identity, {cpu: tuple.hardwareConcurrency, memory: tuple.webDeviceMemoryGB, screen: tuple.screen,
    hints: {platform: 'macOS', platformVersion: tuple.platformVersion, architecture: 'arm', bitness: '64', mobile: false}});
  assert.deepEqual(data.contexts.map(x => x.type), ['webgl', 'webgl2']);
  for (const context of data.contexts) {
    assert.deepEqual(context.first, context.repeat, 'Capabilities changed between reads');
    const first = context.first;
    assert.equal(first.renderer, `ANGLE (Apple, ANGLE Metal Renderer: Apple ${tuple.gpuModel}, Unspecified Version)`);
    assert.equal(first.vendor, 'Google Inc. (Apple)');
    const names = ['MAX_TEXTURE_SIZE', 'MAX_CUBE_MAP_TEXTURE_SIZE', 'MAX_RENDERBUFFER_SIZE', 'MAX_VERTEX_ATTRIBS',
      'MAX_VERTEX_TEXTURE_IMAGE_UNITS', 'MAX_TEXTURE_IMAGE_UNITS', 'MAX_COMBINED_TEXTURE_IMAGE_UNITS',
      'MAX_VIEWPORT_DIMS', 'ALIASED_POINT_SIZE_RANGE'];
    if (context.type === 'webgl2') names.push('MAX_3D_TEXTURE_SIZE', 'MAX_ARRAY_TEXTURE_LAYERS',
      'MAX_DRAW_BUFFERS', 'MAX_COLOR_ATTACHMENTS', 'MAX_UNIFORM_BUFFER_BINDINGS');
    assert.deepEqual(Object.keys(first.limits).sort(), names.sort());
    for (const [name, limit] of Object.entries(first.limits)) {
      if (['MAX_VIEWPORT_DIMS', 'ALIASED_POINT_SIZE_RANGE'].includes(name)) {
        assert(Array.isArray(limit) && limit.length === 2 && limit.every(v => Number.isFinite(v) && v > 0));
      } else assert(Number.isInteger(limit) && limit > 0);
    }
    assert(first.limits.MAX_COMBINED_TEXTURE_IMAGE_UNITS >= first.limits.MAX_TEXTURE_IMAGE_UNITS);
    assert(first.limits.MAX_COMBINED_TEXTURE_IMAGE_UNITS >= first.limits.MAX_VERTEX_TEXTURE_IMAGE_UNITS);
    assert(Array.isArray(first.extensions) && first.extensions.length > 0);
    assert.deepEqual(first.extensions, [...new Set(first.extensions)].sort());
    assert(first.extensions.includes('WEBGL_debug_renderer_info'));
    assert.deepEqual(first.precision.map(x => x.stage), ['VERTEX_SHADER', 'FRAGMENT_SHADER']);
    for (const p of first.precision) for (const key of ['rangeMin', 'rangeMax', 'precision']) assert(Number.isInteger(p[key]) && p[key] > 0);
    for (const key of ['extensionsUsable', 'framebufferComplete', 'oversizeRejected', 'invalidEnumRejected', 'drawSucceeded', 'blueFill']) assert.equal(context[key], true, key);
    assert.equal(context.oversizeError, 1281); assert.equal(context.invalidError, 1280); assert.equal(context.drawError, 0);
    assert.equal(context.boundaryError, 0); assert.equal(context.boundaryWidth, first.limits.MAX_TEXTURE_SIZE);
    assert(context.boundaryWidth <= 65536);
    assert(Array.isArray(context.pixels) && context.pixels.length === 256);
    assert(context.pixels.every((v, i) => Number.isInteger(v) && v >= 0 && v <= 255 && (i % 4 >= 2 ? v >= 254 : v <= 1)));
  }
  return {status: 'scoped-cohort-capabilities-pass', WebGLContexts: 2, hardwareQualified: false};
}
