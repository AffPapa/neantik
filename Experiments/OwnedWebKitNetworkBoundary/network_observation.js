// Fixed STUN-target operation, not full ICE negotiation or a media-call test.
// No raw SDP, candidates, device names or addresses leave this operation.
void (async function (config) {
  const report = {nonce: config.nonce, available: typeof RTCPeerConnection === 'function',
    secureContext: isSecureContext, offerCreated: false, gatheringComplete: false,
    timedOut: false, closed: false,
    candidates: {host: 0, srflx: 0, prflx: 0, relay: 0, other: 0}, errorCodes: []};
  let peer, timer, finishTarget = () => {};
  try {
    if (!report.available || !report.secureContext) throw new Error('Unavailable');
    peer = new RTCPeerConnection({iceServers: [{urls: config.stunURL}]});
    peer.onicecandidate = event => {
      if (event.candidate) {
        const type = event.candidate.type;
        report.candidates[Object.hasOwn(report.candidates, type) ? type : 'other']++;
        if (type === 'srflx') finishTarget();
      }
    };
    peer.onicecandidateerror = event => {
      const sameTarget = event.url === config.stunURL || event.url === config.stunURL + '?transport=udp';
      if (sameTarget && Number.isInteger(event.errorCode) && report.errorCodes.length < 16)
        report.errorCodes.push(event.errorCode);
      if (sameTarget && event.errorCode === 701) finishTarget();
    };
    const gathered = new Promise(resolve => {
      finishTarget = () => { clearTimeout(timer); resolve(); };
      peer.onicegatheringstatechange = () => {
        if (peer.iceGatheringState === 'complete') {
          report.gatheringComplete = true; clearTimeout(timer); resolve();
        }
      };
      timer = setTimeout(() => { report.timedOut = true; resolve(); }, 40000);
    });
    peer.createDataChannel('owned-network-qa');
    await peer.setLocalDescription(await peer.createOffer());
    report.offerCreated = true;
    await gathered;
  } catch { /* The explicit fields retain the incomplete operation. */ }
  finally {
    clearTimeout(timer);
    if (peer) {
      peer.onicecandidate = peer.onicecandidateerror = peer.onicegatheringstatechange = null;
      peer.close(); report.closed = peer.connectionState === 'closed';
    }
    window.webkit.messageHandlers.ownedNetworkResult.postMessage(report);
  }
})
