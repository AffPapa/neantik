// Public verification only. The signing key stays at the owned Sites endpoint.
import {createHash, createPublicKey, verify, generateKeyPairSync, sign} from 'node:crypto';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';

const endpoint = 'https://browser.free/api/route-qa/https';
const endpointHash = createHash('sha256').update(endpoint).digest('hex');
const pinnedKey = createPublicKey({key: Buffer.concat([
  Buffer.from('302a300506032b6570032100', 'hex'),
  Buffer.from('mT19pqlD/5uCjezfSL1yyY5dp/7G4biCkPFbJsRqLqo=', 'base64'),
]), format: 'der', type: 'spki'});

function decode(value, maximum) {
  assert(typeof value === 'string' && /^[A-Za-z0-9_-]+$/.test(value) && value.length <= maximum);
  const data = Buffer.from(value, 'base64url');
  assert.equal(data.toString('base64url'), value);
  return data;
}

export function receiptValid(input, key = pinnedKey) {
  try {
    assert.deepEqual(Object.keys(input).sort(), ['nonce', 'now', 'r', 's']);
    assert(/^[0-9a-f]{64}$/.test(input.nonce) && Number.isSafeInteger(input.now));
    const payload = decode(input.r, 2048), signature = decode(input.s, 86);
    assert.equal(signature.length, 64);
    assert(verify(null, payload, key, signature));
    const data = JSON.parse(payload.toString('utf8'));
    // The owned endpoint emits this closed canonical JSON shape. Re-encoding
    // also rejects duplicate keys, nonfinite values and ambiguous encodings.
    assert.equal(JSON.stringify(data), payload.toString('utf8'));
    assert.deepEqual(Object.keys(data).sort(), ['component', 'endpointSHA256', 'expiresAt', 'nonce', 'schema']);
    assert.equal(data.schema, 1); assert.equal(data.component, 'https');
    assert.equal(data.nonce, input.nonce); assert.equal(data.endpointSHA256, endpointHash);
    assert(Number.isSafeInteger(data.expiresAt) && data.expiresAt > input.now && data.expiresAt <= input.now + 8);
    return true;
  } catch { return false; }
}

function selfTest() {
  const {privateKey, publicKey} = generateKeyPairSync('ed25519');
  const nonce = 'a'.repeat(64), now = 1000;
  const payload = {schema: 1, component: 'https', nonce, endpointSHA256: endpointHash, expiresAt: now + 8};
  const make = (data = payload) => {
    const bytes = Buffer.from(JSON.stringify(data));
    return {r: bytes.toString('base64url'), s: sign(null, bytes, privateKey).toString('base64url'), nonce, now};
  };
  assert(receiptValid(make(), publicKey));
  const controls = [
    {...make(), nonce: 'b'.repeat(64)}, {...make(), now: 1008}, {...make(), s: 'A'.repeat(86)},
    make({...payload, component: 'http'}), make({...payload, endpointSHA256: 'b'.repeat(64)}),
    make({...payload, expiresAt: now + 9}), make({...payload, schema: true}),
    {...make(), extra: 'not-admitted'}, {...make(), r: make().r + '='},
  ];
  assert(controls.every(value => !receiptValid(value, publicKey)));
  assert(!receiptValid(make())); // A different real Ed25519 signer is rejected.
  return {positiveControls: 1, negativeControls: controls.length + 1, actualBrowser: false};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length === 3 && process.argv[2] === '--self-test') {
    console.log(JSON.stringify(selfTest()));
  } else {
    let data = '', exceeded = false;
    for await (const chunk of process.stdin) {
      if (Buffer.byteLength(data) + chunk.length > 8192) { exceeded = true; break; }
      data += chunk.toString('utf8');
    }
    let valid = false;
    try { valid = !exceeded && receiptValid(JSON.parse(data)); } catch {}
    console.log(JSON.stringify({valid})); process.exitCode = valid ? 0 : 1;
  }
}
