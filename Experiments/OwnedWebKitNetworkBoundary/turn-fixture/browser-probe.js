// Evaluate in the owned synthetic browser document. Signaling stays in memory.
(async function probeOwnedTURN({url, username, credential}) {
  const endpoint = typeof url === 'string' &&
    /^turns?:(?:127\.0\.0\.1|[a-z0-9-]+\.invalid):([1-9][0-9]{0,4})\?transport=tcp$/.exec(url);
  if (!endpoint || endpoint[0] !== url || Number(endpoint[1]) > 65535 ||
      typeof username !== 'string' || !username || username.length > 128 ||
      typeof credential !== 'string' || !credential || credential.length > 256) {
    return {status: 'fixture-invalid'};
  }
  if (!globalThis.isSecureContext || typeof RTCPeerConnection !== 'function') {
    return {status: 'api-unavailable'};
  }

  const config = {iceServers: [{urls: url, username, credential}], iceTransportPolicy: 'relay'};
  const selectedPairUsesRelay = async peer => {
    const stats = await peer.getStats();
    const transports = [...stats.values()].filter(item => item.type === 'transport' && item.selectedCandidatePairId);
    if (transports.length !== 1) return false;
    const pair = stats.get(transports[0].selectedCandidatePairId);
    return pair?.type === 'candidate-pair' && pair.state === 'succeeded' &&
      pair.bytesSent > 0 && pair.bytesReceived > 0 &&
      stats.get(pair.localCandidateId)?.candidateType === 'relay' &&
      stats.get(pair.remoteCandidateId)?.candidateType === 'relay';
  };
  const gather = async (peer, description) => {
    await peer.setLocalDescription(description);
    if (peer.iceGatheringState !== 'complete') {
      await new Promise(resolve => {
        const observe = () => {
          if (peer.iceGatheringState !== 'complete') return;
          peer.removeEventListener('icegatheringstatechange', observe);
          resolve();
        };
        peer.addEventListener('icegatheringstatechange', observe);
        observe();
      });
    }
    const local = peer.localDescription;
    const candidates = local.sdp.split(/\r?\n/).filter(line => line.startsWith('a=candidate:'));
    if (!candidates.length || candidates.some(line => !/\styp relay(?:\s|$)/.test(line))) return null;
    return local;
  };

  let left, right, timer;
  try {
    left = new RTCPeerConnection(config);
    right = new RTCPeerConnection(config);
    const nonce = [...crypto.getRandomValues(new Uint8Array(16))]
      .map(byte => byte.toString(16).padStart(2, '0')).join('');
    const channel = left.createDataChannel('owned-turn-control');
    const exchange = new Promise(resolve => {
      right.ondatachannel = ({channel: incoming}) => {
        incoming.onmessage = event => {
          if (event.data !== nonce) return resolve(false);
          incoming.send('ack:' + nonce);
        };
      };
      channel.onopen = () => channel.send(nonce);
      channel.onmessage = event => resolve(event.data === 'ack:' + nonce);
    });
    const run = async () => {
      const offer = await gather(left, await left.createOffer());
      if (!offer) return 'relay-candidate-missing';
      await right.setRemoteDescription(offer);
      const answer = await gather(right, await right.createAnswer());
      if (!answer) return 'relay-candidate-missing';
      await left.setRemoteDescription(answer);
      if (!await exchange) return 'nonce-mismatch';
      const pairs = await Promise.all([selectedPairUsesRelay(left), selectedPairUsesRelay(right)]);
      return pairs.every(Boolean) ? 'relay-nonce-delivered' : 'relay-pair-unverified';
    };
    const timeout = new Promise(resolve => { timer = setTimeout(() => resolve('timeout'), 15000); });
    return {status: await Promise.race([run(), timeout])};
  } catch (_) {
    return {status: 'browser-error'};
  } finally {
    clearTimeout(timer);
    left?.close();
    right?.close();
  }
})
