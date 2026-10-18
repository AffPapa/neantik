import assert from 'node:assert/strict';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {frame, decodeClientFrame} from './websocket-fixture.mjs';
import {verifyWebSocketRoute} from './websocket-route-verify.mjs';

export function fixture(mode) {
  const probe = {kind: 'owned-websocket-route-operations', mode, errors: [], socketsRemaining: 0, rows: [], held: []}, events = [];
  for (const protocol of ['ws', 'wss']) {
    probe.held.push(mode === 'protected' ? {protocol, abortedByProxyStop: true, closeCode: 1006} : {protocol, stillOpenAfterProxyStop: true});
    for (const phase of ['initial', 'blocked', 'recovered']) {
      const blocked = phase === 'blocked' && mode === 'protected';
      probe.rows.push({protocol, phase, opened: !blocked, echoed: !blocked, errored: blocked, timedOut: false,
        closeCode: blocked || phase === 'initial' && mode === 'protected' ? 1006 : 1000});
      if (!blocked) {
        events.push({kind: 'handshake', phase, protocol, route: mode === 'protected' ? 'proxy' : 'direct', echoed: true, closed: true});
        if (mode === 'protected') events.push({kind: 'tunnel', phase, protocol});
      }
    }
  }
  return {probe, events, mode, transitions: ['blocked', 'recovered']};
}
export const mutations = [
  ['missing-operation', v => v.probe.rows.pop()], ['duplicate-operation', v => v.probe.rows[1] = structuredClone(v.probe.rows[0])],
  ['missing-echo', v => v.probe.rows[0].echoed = false], ['timeout-not-refusal', v => v.probe.rows.find(r => r.phase === 'blocked').timedOut = true],
  ['failed-held-tunnel', v => v.probe.held[0].abortedByProxyStop = false], ['normal-close-not-abort', v => v.probe.held[0].closeCode = 1000],
  ['missing-error-event', v => v.probe.rows.find(r => r.phase === 'blocked').errored = false], ['direct-on-failure', v => v.events.push({kind: 'handshake', protocol: 'ws', phase: 'blocked', route: 'direct', echoed: true, closed: true})],
  ['wrong-socket-route', v => v.events.find(e => e.kind === 'handshake').route = 'direct'], ['no-origin-echo', v => v.events.find(e => e.kind === 'handshake').echoed = false],
  ['missing-wss', v => v.probe.rows = v.probe.rows.filter(r => r.protocol !== 'wss')], ['no-listener-stop', v => v.transitions.shift()],
  ['no-recovery', v => v.probe.rows.find(r => r.phase === 'recovered').opened = false], ['missing-tunnel', v => v.events.splice(v.events.findIndex(e => e.kind === 'tunnel'), 1)],
  ['socket-left-open', v => v.probe.socketsRemaining = 1], ['operation-error', v => v.probe.errors.push('failed')],
  ['unknown-phase', v => v.events[0].phase = 'unknown'], ['no-native-close', v => v.events.find(e => e.kind === 'handshake').closed = false]
];
const assess = v => verifyWebSocketRoute(v.probe, v.events, v.mode, v.transitions);
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
for (const mode of ['protected', 'bypass-control']) assert.equal(assess(fixture(mode)).issues.length, 0);
for (const [name, mutate] of mutations) { const value = fixture('protected'); mutate(value); assert(assess(value).issues.length > 0, name); }
const direct = fixture('bypass-control'); direct.mode = 'protected'; direct.probe.mode = 'protected'; assert(assess(direct).issues.length > 0, 'Real bypass must be rejected as protected');

const message = Buffer.from('own-fixed-payload'), mask = Buffer.from([1, 2, 3, 4]);
const masked = Buffer.concat([Buffer.from([0x81, 0x80 | message.length]), mask, Buffer.from(message.map((v, i) => v ^ mask[i % 4]))]);
assert.equal(decodeClientFrame(masked).payload.toString(), message.toString());
for (let i = 0; i < masked.length; i++) assert.equal(decodeClientFrame(masked.subarray(0, i)), null);
assert.deepEqual(frame(message), Buffer.concat([Buffer.from([0x81, message.length]), message]));
for (const bytes of [Buffer.from([0x81, 1]), Buffer.from([0x01, 0x80]), Buffer.from([0xc1, 0x80]), Buffer.from([0x81, 0xfe])]) assert.throws(() => decodeClientFrame(bytes));
assert.throws(() => frame(Buffer.alloc(126)));
console.log(JSON.stringify({status: 'passed-websocket-model-and-wire-controls', positiveModels: 2, negativeModels: mutations.length + 1, actualBrowser: false}));
}
