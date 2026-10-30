(async () => {
  const config = await (await fetch('/stun-config', {cache: 'no-store'})).json();
  if (config.nonce !== document.body.dataset.ownFixture) throw Error('WrongOwnedSTUNDocument');
  const peer = new RTCPeerConnection({iceServers: [{urls: config.url}]});
  let timer, complete = false, timedOut = false;
  const candidates = {host: 0, srflx: 0, prflx: 0, relay: 0, other: 0};
  const errorCodes = [];
  try {
    peer.onicecandidate = event => {
      if (event.candidate) {
        // Export category counts only, never SDP, addresses or raw ICE.
        const type = event.candidate.type;
        candidates[Object.hasOwn(candidates, type) ? type : 'other']++;
      }
    };
    peer.onicecandidateerror = event => {
      if (errorCodes.length < 16 && Number.isInteger(event.errorCode)) errorCodes.push(event.errorCode);
    };
    peer.createDataChannel('owned-loopback-control');
    const gathering = new Promise(resolve => {
      peer.onicegatheringstatechange = () => {
        if (peer.iceGatheringState === 'complete') {
          complete = true; clearTimeout(timer); resolve();
        }
      };
      timer = setTimeout(() => {timedOut = true; resolve();}, 12000);
    });
    await peer.setLocalDescription(await peer.createOffer());
    await gathering;
    return {kind: 'owned-webrtc-boundary', nonce: config.nonce, gatheringComplete: complete,
      iceGatheringState: peer.iceGatheringState, timedOut, candidates, errorCodes, rawICEExported: false};
  } finally {
    clearTimeout(timer); peer.onicecandidate = null; peer.onicecandidateerror = null; peer.close();
  }
})()
