// Runs only in the controller's own loopback document, never a real website.
// Capabilities declarations are observations; decoding and playback are separate.
(async () => {
  const nonce = document.documentElement.dataset.nonce;
  const {cases} = await (await fetch('/manifest.json')).json();
  const bounded = (promise, ms = 6500) => {
    let timer;
    return Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(Error('timeout')), ms);
    })]).finally(() => clearTimeout(timer));
  };
  const digest = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), x => x.toString(16).padStart(2, '0')).join('');
  const rows = [];
  const audio = new OfflineAudioContext(1, 48000, 48000);
  for (const c of cases) {
    const row = {id: c.id, kind: c.kind};
    const media = document.createElement(c.kind);
    media.muted = true; media.preload = 'auto';
    media.style.cssText = 'width:64px;height:48px';
    document.body.append(media);
    try {
      const bytes = await (await fetch('/' + c.file)).arrayBuffer();
      row.assetSHA256 = await digest(bytes);
      row.canPlayType = media.canPlayType(c.mime);
      const config = c.kind === 'video'
        ? {type: 'file', video: {contentType: c.mime, width: 64, height: 48, bitrate: 50000, framerate: 20}}
        : {type: 'file', audio: {contentType: c.mime, channels: '1', bitrate: 128000, samplerate: 48000}};
      try {
        const caps = await bounded(navigator.mediaCapabilities.decodingInfo(config));
        row.capabilities = {supported: caps.supported, smooth: caps.smooth, powerEfficient: caps.powerEfficient};
      } catch (error) { row.capabilities = {error: error.name}; }
      if (c.kind === 'audio') {
        const decoded = await bounded(audio.decodeAudioData(bytes.slice(0)));
        const samples = decoded.getChannelData(0);
        let energy = 0, crossings = 0;
        for (let i = 0; i < samples.length; i++) {
          energy += samples[i] ** 2;
          if (i && samples[i - 1] <= 0 && samples[i] > 0) crossings++;
        }
        row.decoded = {sampleRate: decoded.sampleRate, channels: decoded.numberOfChannels,
          seconds: decoded.duration, rms: Math.sqrt(energy / samples.length), hertz: crossings / decoded.duration};
      }
      const source = URL.createObjectURL(new Blob([bytes], {type: c.mime.split(';')[0]}));
      try {
        media.src = source;
        await bounded(media.play());
        const start = media.currentTime;
        await bounded(new Promise((resolve, reject) => {
          const deadline = performance.now() + 5000;
          const tick = () => {
            if (media.error) { reject(Error('media-error')); return; }
            if (performance.now() > deadline) { reject(Error('playback-timeout')); return; }
            if (media.currentTime >= start + 0.2) { resolve(); return; }
            setTimeout(tick, 20);
          };
          tick();
        }));
        row.playback = {advanced: media.currentTime - start, ended: media.ended, readyState: media.readyState};
        if (c.kind === 'video') {
          row.dimensions = [media.videoWidth, media.videoHeight];
          row.decodedFrames = media.getVideoPlaybackQuality().totalVideoFrames;
          const canvas = document.createElement('canvas'); canvas.width = 64; canvas.height = 48;
          const ctx = canvas.getContext('2d'); ctx.drawImage(media, 0, 0);
          row.pixel = Array.from(ctx.getImageData(30, 20, 1, 1).data);
        }
      } finally { media.pause(); media.removeAttribute('src'); media.load(); URL.revokeObjectURL(source); }
      row.status = 'decoded-and-played';
    } catch (error) { row.status = 'failed'; row.error = error.name; }
    finally { media.remove(); }
    rows.push(row);
  }
  // An invalid container must actually fail decode, despite an advertised MIME.
  let brokenMedia;
  try {
    await bounded(audio.decodeAudioData(await (await fetch('/invalid.webm')).arrayBuffer()));
    brokenMedia = 'incorrectly-decoded';
  } catch (error) { brokenMedia = error.name === 'EncodingError' ? 'decode-rejected' : 'inconclusive'; }
  let invalidConfiguration;
  try { await bounded(navigator.mediaCapabilities.decodingInfo({type: 'file'})); invalidConfiguration = 'incorrectly-accepted'; }
  catch (error) { invalidConfiguration = error.name; }
  document.querySelector('#status').textContent = 'Own media observations complete';
  await fetch('/result', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({nonce, kind: 'actual-codec-playback', rows, brokenMedia, invalidConfiguration})});
})().catch(async error => {
  await fetch('/result', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({nonce: document.documentElement.dataset.nonce, kind: 'harness-failed', error: error.name})});
});
