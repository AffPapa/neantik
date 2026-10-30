import assert from 'node:assert/strict';
import fs from 'node:fs';
import {COHORTS, verifyProbe} from './verify.mjs';
const tuple = JSON.parse(fs.readFileSync(new URL('../../runtime/apple-device-tuples.json', import.meta.url))).tuples[0];
const limits = {MAX_TEXTURE_SIZE: 16384, MAX_CUBE_MAP_TEXTURE_SIZE: 16384, MAX_RENDERBUFFER_SIZE: 16384,
  MAX_VERTEX_ATTRIBS: 16, MAX_VERTEX_TEXTURE_IMAGE_UNITS: 16, MAX_TEXTURE_IMAGE_UNITS: 16,
  MAX_COMBINED_TEXTURE_IMAGE_UNITS: 32, MAX_VIEWPORT_DIMS: [16384, 16384], ALIASED_POINT_SIZE_RANGE: [1, 64]};
const make = type => {
  const first = {renderer: 'ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)', vendor: 'Google Inc. (Apple)',
    limits: {...limits, ...(type === 'webgl2' ? {MAX_3D_TEXTURE_SIZE: 2048, MAX_ARRAY_TEXTURE_LAYERS: 256,
      MAX_DRAW_BUFFERS: 8, MAX_COLOR_ATTACHMENTS: 8, MAX_UNIFORM_BUFFER_BINDINGS: 24} : {})},
    extensions: ['WEBGL_debug_renderer_info'], precision: ['VERTEX_SHADER', 'FRAGMENT_SHADER'].map(stage => ({stage, rangeMin: 14, rangeMax: 14, precision: 10}))};
  return {type, first, repeat: structuredClone(first), extensionsUsable: true, framebufferComplete: true,
    oversizeRejected: true, invalidEnumRejected: true, drawSucceeded: true, blueFill: true,
    pixels: Array.from({length: 256}, (_, i) => i % 4 >= 2 ? 255 : 0),
    oversizeError: 1281, drawError: 0, invalidError: 1280, boundaryWidth: 16384, boundaryError: 0};
};
const positive = {schemaVersion: 1, errors: [], identity: {cpu: tuple.hardwareConcurrency, memory: tuple.webDeviceMemoryGB,
  screen: tuple.screen, hints: {platform: 'macOS', platformVersion: tuple.platformVersion, architecture: 'arm', bitness: '64', mobile: false}},
  contexts: ['webgl', 'webgl2'].map(make)};
assert.equal(verifyProbe(positive, tuple).status, 'scoped-cohort-capabilities-pass');
const both = (c, change) => { change(c.contexts[0].first); c.contexts[0].repeat = structuredClone(c.contexts[0].first); };
const mutations = [
  c => c.contexts.pop(), c => c.errors.push('ContextLost'), c => c.identity.cpu++, c => c.identity.hints.platformVersion = '0',
  c => both(c, p => p.renderer = 'Apple M1 Pro'), c => c.contexts[0].repeat.limits.MAX_TEXTURE_SIZE++,
  c => both(c, p => p.limits.MAX_TEXTURE_SIZE = 8192),
  c => c.contexts[0].extensionsUsable = false, c => c.contexts[1].framebufferComplete = false,
  c => c.contexts[0].oversizeError = 0, c => c.contexts[0].boundaryError = 1281,
  c => c.contexts[0].invalidError = 0, c => c.contexts[0].drawError = 1282,
  c => c.contexts[0].pixels.fill(0), c => c.contexts[0].pixels[1] = 2,
  c => both(c, p => p.precision[0].precision = 0),
  c => both(c, p => delete p.limits.MAX_VERTEX_ATTRIBS),
  c => both(c, p => p.extensions = ['WEBGL_debug_renderer_info', 'WEBGL_debug_renderer_info']),
];
for (const mutate of mutations) { const broken = structuredClone(positive); mutate(broken); assert.throws(() => verifyProbe(broken, tuple)); }
assert.deepEqual(COHORTS.map(c => c.seed), [11, 13, 16, 19]);
console.log(JSON.stringify({status: 'PASS', positiveControls: 1, negativeControls: mutations.length, actualBrowser: false}));
