// Consume a private custody receipt immediately after collection.
// The only permitted navigation is the exact owned loopback fixture page.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

export function endpoints(custody, fixture) {
  assert.equal(custody.status, 'observed');
  assert.match(custody.candidateArchiveSHA256, /^[a-f0-9]{64}$/);
  assert.match(custody.websocket, /^ws:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}\/devtools\/browser\/[a-f0-9-]{36}$/);
  assert.equal(fixture.status, 'ready');
  assert.match(fixture.pageTitlePrefix, /^[a-f0-9]{24}:$/);
  const nonce = fixture.pageTitlePrefix.slice(0, -1);
  assert.match(fixture.browserURL, /^http:\/\/neantik-[a-f0-9]{24}\.invalid:[1-9][0-9]{0,4}\/$/);
  assert.equal(new URL(fixture.browserURL).hostname, `neantik-${nonce}.invalid`);
  return {websocket: new URL(custody.websocket).href, target: new URL(fixture.browserURL).href};
}

function readPrivate(file) {
  assert.equal(fs.realpathSync(file), file);
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const info = fs.fstatSync(fd);
    assert(info.isFile() && info.uid === process.getuid() && (info.mode & 0o077) === 0
           && info.nlink === 1 && info.size <= 16384);
    return JSON.parse(fs.readFileSync(fd, 'utf8'));
  } finally {
    fs.closeSync(fd);
  }
}

export async function observe(command, target, title, mode) {
  const existing = await command('Target.getTargets');
  const pages = existing.targetInfos.filter(item => item.type === 'page');
  const baseTarget = target.replace(/\?rtc=1$/, '');
  assert(pages.length === 1 && ['about:blank', baseTarget, 'chrome-error://chromewebdata/'].includes(pages[0].url),
    'unexpected QA tabs');
  const targetId = pages[0].targetId;
  const {sessionId} = await command('Target.attachToTarget', {targetId, flatten: true});
  const result = await command('Page.navigate', {url: target}, sessionId);
  if (mode === 'refused' && result.errorText) {
    assert.match(result.errorText, /^net::ERR_(PROXY_CONNECTION_FAILED|TUNNEL_CONNECTION_FAILED|HTTP_RESPONSE_CODE_FAILURE)$/);
    return {status: 'browser-navigation-refused', error: result.errorText};
  }
  if (result.errorText) {
    throw Error(/^net::ERR_[A-Z_]+$/.test(result.errorText) ? result.errorText : 'browser navigation refused');
  }
  const deadline = Date.now() + (mode === 'rtc' ? 15000 : 5000);
  while (Date.now() < deadline) {
    const {targetInfo} = await command('Target.getTargetInfo', {targetId});
    if (targetInfo.url === target && targetInfo.title === title) {
      if (mode === 'refused') return {status: 'fixture-refusal-page-observed'};
      if (mode === 'rtc') return {status: 'browser-webrtc-gathering-completed'};
      return {status: 'browser-page-observed', storage: mode};
    }
    await new Promise(resolve => setTimeout(resolve, 80));
  }
  throw Error('owned page and storage marker did not appear');
}

async function main() {
  const [custodyPath, fixturePath, mode] = process.argv.slice(2);
  assert(process.argv.length === 5 && ['fresh', 'restored', 'refused', 'rtc'].includes(mode));
  const custody = readPrivate(custodyPath);
  const fixture = readPrivate(fixturePath);
  const {websocket, target} = endpoints(custody, fixture);
  const socket = new WebSocket(websocket);
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error('CDP open timeout')), 4000);
      socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, {once: true});
      socket.addEventListener('error', () => { clearTimeout(timer); reject(Error('CDP open refused')); }, {once: true});
    });
    let id = 0;
    function command(method, params = {}, sessionId) {
      const sequence = ++id;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          socket.removeEventListener('message', receive);
          reject(Error('CDP response timeout'));
        }, 5000);
        function receive(event) {
          let message;
          try { message = JSON.parse(event.data); } catch { return; }
          if (message.id !== sequence) return;
          clearTimeout(timer);
          socket.removeEventListener('message', receive);
          if (message.error) reject(Error('CDP command refused'));
          else resolve(message.result);
        }
        socket.addEventListener('message', receive);
        socket.send(JSON.stringify({id: sequence, method, params, sessionId}));
      });
    }
    const result = await observe(command, mode === 'rtc' ? target + '?rtc=1' : target,
      fixture.pageTitlePrefix + (mode === 'rtc' ? 'restored:rtc-complete' : mode), mode);
    console.log(JSON.stringify({...result, candidateArchiveSHA256: custody.candidateArchiveSHA256,
      profileID: custody.profileID, browserGeneration: custody.browser, proxyRouteVerified: false}));
  } finally {
    socket.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => {
    const safeMessages = new Set(['unexpected QA tabs', 'browser navigation refused',
      'owned page and storage marker did not appear', 'CDP open timeout',
      'CDP open refused', 'CDP response timeout', 'CDP command refused']);
    console.error(safeMessages.has(error?.message) || /^net::ERR_[A-Z_]+$/.test(error?.message)
      ? error.message : 'invalid-observation-input');
    process.exitCode = 1;
  });
}
