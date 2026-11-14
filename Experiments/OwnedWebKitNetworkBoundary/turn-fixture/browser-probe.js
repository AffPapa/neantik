// Evaluate in the owned synthetic browser document. Signaling stays in memory.
(async function probeOwnedTURN({url, username, credential, challengeRelayPolicy = false}) {
  const endpoint = typeof url === 'string' &&
    /^turns?:(?:127\.0\.0\.1|[a-z0-9-]+\.invalid):([1-9][0-9]{0,4})\?transport=tcp$/.exec(url);
  if (typeof challengeRelayPolicy !== 'boolean' || !endpoint || endpoint[0] !== url || Number(endpoint[1]) > 65535 ||
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
    if (transports.length !== 1) return 'transport';
    const pair = stats.get(transports[0].selectedCandidatePairId);
    if (pair?.type !== 'candidate-pair' || pair.state !== 'succeeded') return 'state';
    const localType = stats.get(pair.localCandidateId)?.candidateType;
    const remoteType = stats.get(pair.remoteCandidateId)?.candidateType;
    if (!localType || !remoteType) return 'missing-candidate';
    if (localType !== 'relay') return 'local-candidate';
    if (remoteType !== 'relay') return 'remote-candidate';
    if (!(pair.bytesSent > 0 && pair.bytesReceived > 0)) return 'bytes';
    return 'verified';
  };
  let nonRelayObserved = false;
  let signalingError = false;
  const isRelay = candidate => /\styp relay(?:\s|$)/.test(candidate);
  const gather = async (peer, description) => {
    await peer.setLocalDescription(description);
    return new Promise(resolve => {
      const observe = event => {
        const candidate = event?.candidate;
        if (candidate?.candidate) {
          if (!isRelay(candidate.candidate)) nonRelayObserved = true;
          else {
            const entry = localCandidates.get(peer);
            if (entry.deliver) entry.deliver(candidate).catch(() => { signalingError = true; });
            else entry.pending.set(candidate.candidate, candidate);
          }
        }
        const local = peer.localDescription;
        const candidates = local.sdp.split(/\r?\n/).filter(line => line.startsWith('a=candidate:'));
        if (candidates.some(line => !isRelay(line))) nonRelayObserved = true;
        if (nonRelayObserved || candidates.length || peer.iceGatheringState === 'complete') {
          resolve(candidates.length && !nonRelayObserved ? local : null);
        }
      };
      // A usable relay description can be signaled while another gathering
      // attempt is outstanding. Keep observing later events until close.
      peer.addEventListener('icecandidate', observe);
      peer.addEventListener('icegatheringstatechange', observe);
      observe();
    });
  };

  let left, right, timer;
  let stage = 'offer';
  let timedOut = false;
  let pairFailure;
  const localCandidates = new Map();
  const candidatesFor = peer => {
    const entry = {pending: new Map(), deliver: null};
    localCandidates.set(peer, entry);
    return entry;
  };
  const signalRemainingCandidates = async (origin, remote, description) => {
    const alreadySignaled = new Set(description.sdp.split(/\r?\n/)
      .filter(line => line.startsWith('a=candidate:')).map(line => line.slice(2)));
    const entry = localCandidates.get(origin);
    entry.deliver = candidate => {
      if (alreadySignaled.has(candidate.candidate)) return Promise.resolve();
      alreadySignaled.add(candidate.candidate);
      return remote.addIceCandidate(candidate);
    };
    await Promise.all([...entry.pending.values()].map(entry.deliver));
    entry.pending.clear();
  };
  try {
    if (challengeRelayPolicy) {
      const explicit = {...config, iceTransportPolicy: 'all'};
      const omitted = {iceServers: config.iceServers};
      left = new RTCPeerConnection(explicit);
      right = new RTCPeerConnection(omitted);
      if ([left, right].some(peer => peer.getConfiguration().iceTransportPolicy !== 'relay')) {
        return {status: 'relay-policy-escaped'};
      }
      left.setConfiguration(explicit);
      right.setConfiguration(omitted);
      if ([left, right].some(peer => peer.getConfiguration().iceTransportPolicy !== 'relay')) {
        return {status: 'relay-policy-escaped'};
      }
    } else {
      left = new RTCPeerConnection(config);
      right = new RTCPeerConnection(config);
    }
    candidatesFor(left);
    candidatesFor(right);
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
      stage = 'answer';
      await right.setRemoteDescription(offer);
      await signalRemainingCandidates(left, right, offer);
      const answer = await gather(right, await right.createAnswer());
      if (!answer) return 'relay-candidate-missing';
      await left.setRemoteDescription(answer);
      await signalRemainingCandidates(right, left, answer);
      stage = 'exchange';
      if (!await exchange) return 'nonce-mismatch';
      stage = 'stats';
      do {
        const pairs = await Promise.all([selectedPairUsesRelay(left), selectedPairUsesRelay(right)]);
        if (signalingError) return 'browser-error';
        if (nonRelayObserved) return 'relay-policy-escaped';
        pairFailure = pairs.find(pair => pair !== 'verified');
        if (!pairFailure) return 'relay-nonce-delivered';
        if (pairFailure === 'local-candidate') {
          return 'relay-pair-unverified-' + pairFailure;
        }
        await new Promise(resolve => setTimeout(resolve, 100));
      } while (!timedOut);
      return 'relay-pair-unverified';
    };
    const timeout = new Promise(resolve => {
      timer = setTimeout(() => {
        timedOut = true;
        resolve(pairFailure ? 'relay-pair-unverified-' + pairFailure : 'timeout-' + stage);
      }, 15000);
    });
    return {status: await Promise.race([run(), timeout])};
  } catch (_) {
    return {status: 'browser-error'};
  } finally {
    clearTimeout(timer);
    left?.close();
    right?.close();
  }
})
