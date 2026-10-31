// Only synthetic, configured cohorts and an owned page. No installed-font,
// media-device, voice, ICE or real-user storage inventory is collected.
(async () => {
  const nonce = document.documentElement.dataset.nonce;
  const observation = {schemaVersion: 1, nonce, errors: [], identity: null, contexts: []};
  try {
    const hints = await navigator.userAgentData.getHighEntropyValues(['platformVersion', 'architecture', 'bitness']);
    observation.identity = {cpu: navigator.hardwareConcurrency, memory: navigator.deviceMemory,
      screen: [screen.width, screen.height, screen.availWidth, screen.availHeight, screen.colorDepth, devicePixelRatio].join('x'),
      hints: Object.fromEntries(['platform', 'platformVersion', 'architecture', 'bitness', 'mobile'].map(k => [k, hints[k]]))};
    for (const type of ['webgl', 'webgl2']) {
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 8;
      const gl = canvas.getContext(type, {antialias: false});
      if (!gl) throw Error('Missing-' + type);
      const renderer = gl.getExtension('WEBGL_debug_renderer_info');
      if (!renderer) throw Error('Missing-renderer');
      const names = ['MAX_TEXTURE_SIZE', 'MAX_CUBE_MAP_TEXTURE_SIZE', 'MAX_RENDERBUFFER_SIZE',
        'MAX_VERTEX_ATTRIBS', 'MAX_VERTEX_TEXTURE_IMAGE_UNITS', 'MAX_TEXTURE_IMAGE_UNITS',
        'MAX_COMBINED_TEXTURE_IMAGE_UNITS', 'MAX_VIEWPORT_DIMS', 'ALIASED_POINT_SIZE_RANGE'];
      if (type === 'webgl2') names.push('MAX_3D_TEXTURE_SIZE', 'MAX_ARRAY_TEXTURE_LAYERS',
        'MAX_DRAW_BUFFERS', 'MAX_COLOR_ATTACHMENTS', 'MAX_UNIFORM_BUFFER_BINDINGS');
      const capture = () => ({renderer: gl.getParameter(renderer.UNMASKED_RENDERER_WEBGL),
        vendor: gl.getParameter(renderer.UNMASKED_VENDOR_WEBGL),
        limits: Object.fromEntries(names.map(name => { const v = gl.getParameter(gl[name]);
          return [name, ArrayBuffer.isView(v) ? Array.from(v) : v]; })),
        extensions: gl.getSupportedExtensions().slice().sort(),
        precision: ['VERTEX_SHADER', 'FRAGMENT_SHADER'].map(stage => {
          const p = gl.getShaderPrecisionFormat(gl[stage], gl.MEDIUM_FLOAT);
          return {stage, rangeMin: p.rangeMin, rangeMax: p.rangeMax, precision: p.precision}; })});
      const first = capture(), repeat = capture();
      const extensionsUsable = first.extensions.every(name => gl.getExtension(name) !== null);
      // Exercise the maximum as one row (at most 256KiB), then require max+1
      // rejection. Never allocate a full maximum-size square GPU texture.
      const texture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, texture);
      const boundaryWidth = first.limits.MAX_TEXTURE_SIZE;
      if (!Number.isInteger(boundaryWidth) || boundaryWidth < 1 || boundaryWidth > 65536) throw Error('Unbounded-texture-limit');
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, boundaryWidth, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      const boundaryError = gl.getError();
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, first.limits.MAX_TEXTURE_SIZE + 1,
        1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      const oversizeError = gl.getError();
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 8, 8, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      const framebuffer = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
      const framebufferComplete = gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
      gl.clearColor(0, 0, 1, 1); gl.clear(gl.COLOR_BUFFER_BIT);
      const pixels = new Uint8Array(8 * 8 * 4); gl.readPixels(0, 0, 8, 8, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      const drawError = gl.getError();
      const invalidParameter = gl.getParameter(0xffffffff), invalidError = gl.getError();
      observation.contexts.push({type, first, repeat, extensionsUsable, framebufferComplete,
        oversizeRejected: oversizeError === gl.INVALID_VALUE,
        invalidEnumRejected: invalidParameter === null && invalidError === gl.INVALID_ENUM,
        drawSucceeded: drawError === gl.NO_ERROR, pixels: Array.from(pixels), oversizeError, drawError, invalidError, boundaryWidth, boundaryError,
        // The configured runtime can vary readback by one channel quantum.
        // Solid colour must remain within this fixed pre-observation bound.
        blueFill: pixels.every((v, i) => i % 4 >= 2 ? v >= 254 : v <= 1)});
      gl.deleteFramebuffer(framebuffer); gl.deleteTexture(texture);
      gl.getExtension('WEBGL_lose_context')?.loseContext();
    }
  } catch (error) { observation.errors.push(error.message); }
  await fetch('/result', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(observation)});
})().catch(() => {});
