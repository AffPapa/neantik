// Fixture-only raw CDP transport: protocol errors are observations, while
// transport failures must reject. No browser/runtime qualification is implied.
import assert from 'node:assert/strict';

export function sendOwnedRawCDP(socket, id, method, params = {}, timeoutMS = 10000) {
  assert(Number.isSafeInteger(id) && id > 0);
  assert(typeof method === 'string' && method.startsWith('Storage.'));
  assert(Number.isInteger(timeoutMS) && timeoutMS > 0 && timeoutMS <= 45000);
  assert(socket.readyState === 1, 'Owned CDP transport is not open');
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error, response) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      for (const [name, listener] of listeners) socket.removeEventListener(name, listener);
      error ? reject(error) : resolve(response);
    };
    const message = event => {
      if (typeof event.data !== 'string' || event.data.length > 1024 * 1024) {
        finish(Error('Owned CDP response exceeds bounds')); return;
      }
      let response;
      try { response = JSON.parse(event.data); } catch { finish(Error('Owned CDP response is malformed')); return; }
      if (!response || typeof response !== 'object' || Array.isArray(response)) {
        finish(Error('Owned CDP response is not an object')); return;
      }
      if (response?.id !== id) return;
      if (Object.hasOwn(response, 'sessionId') ||
          Object.hasOwn(response, 'result') === Object.hasOwn(response, 'error')) {
        finish(Error('Owned CDP response has an invalid envelope')); return;
      }
      finish(null, response);
    };
    const fail = () => finish(Error('Owned CDP transport closed or failed'));
    const listeners = [['message', message], ['close', fail], ['error', fail]];
    const timer = setTimeout(() => finish(Error('Owned CDP command timed out')), timeoutMS);
    for (const [name, listener] of listeners) socket.addEventListener(name, listener);
    try { socket.send(JSON.stringify({id, method, params})); }
    catch { finish(Error('Owned CDP command send failed')); }
  });
}
