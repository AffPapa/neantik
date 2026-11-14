import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {runInNewContext} from 'node:vm';

const source = readFileSync(new URL('./browser-probe.js', import.meta.url), 'utf8');
const config = {url: 'turn:synthetic.invalid:51000?transport=tcp', username: 'qa', credential: 'synthetic'};

function fixture({candidate = 'relay', selected = 'relay', corrupt = false, forceRelay = false,
  forceOnUpdate = forceRelay, stallExchange = false, keepGathering = false, lateHost = false,
  lateRelay = false} = {}) {
  const peers = [];
  class Peer {
    constructor(options) {
      this.constructorPolicy = options.iceTransportPolicy;
      this.effectivePolicy = forceRelay ? 'relay' : (options.iceTransportPolicy ?? 'all');
      assert.equal(options.iceServers.length, 1);
      assert.equal(options.iceServers[0].urls, config.url);
      peers.push(this);
    }
    getConfiguration() { return {iceTransportPolicy: this.effectivePolicy}; }
    setConfiguration(options) {
      this.updatedPolicy = options.iceTransportPolicy;
      this.effectivePolicy = forceOnUpdate ? 'relay' : (options.iceTransportPolicy ?? 'all');
    }
    addEventListener(event, handler) {
      this[event] = handler;
    }
    createDataChannel() {
      this.channel = {};
      return this.channel;
    }
    async createOffer() { return {type: 'offer'}; }
    async createAnswer() { return {type: 'answer'}; }
    async setLocalDescription({type}) {
      this.localDescription = {type, sdp: 'a=candidate:synthetic 1 UDP 1 ignored 1 typ ' + candidate + '\r\n'};
      this.iceGatheringState = keepGathering ? 'gathering' : 'complete';
    }
    async setRemoteDescription({type}) {
      if (type !== 'answer') return;
      if (stallExchange) return;
      if (lateHost) this.icecandidate({candidate: {candidate: 'candidate:late 1 UDP 1 ignored 1 typ host'}});
      if (lateRelay) peers[1].icecandidate({candidate: {candidate: 'candidate:late 1 UDP 1 ignored 2 typ relay'}});
      const incoming = {send: data => this.channel.onmessage({data: corrupt ? 'mismatch' : data})};
      peers[1].ondatachannel({channel: incoming});
      this.channel.send = data => incoming.onmessage({data});
      this.channel.onopen();
    }
    async addIceCandidate(candidate) { this.trickledCandidate = candidate; }
    async getStats() {
      return new Map([
        ['transport', {type: 'transport', selectedCandidatePairId: 'pair'}],
        ['pair', {type: 'candidate-pair', state: 'succeeded', localCandidateId: 'local',
          remoteCandidateId: 'remote', bytesSent: 32, bytesReceived: 32}],
        ['local', {candidateType: selected}],
        ['remote', {candidateType: 'relay'}],
      ]);
    }
    close() { this.closed = true; }
  }
  const probe = runInNewContext(source, {
    RTCPeerConnection: Peer, crypto: webcrypto, isSecureContext: true,
    setTimeout: stallExchange ? callback => setTimeout(callback, 10) : setTimeout, clearTimeout,
  });
  return {probe, peers};
}

test('reports a bidirectional nonce and two selected relay pairs without exporting signaling', async () => {
  const {probe, peers} = fixture();
  assert.equal(JSON.stringify(await probe(config)), '{"status":"relay-nonce-delivered"}');
  assert.equal(peers.length, 2);
  assert.ok(peers.every(peer => peer.closed));
});

test('signals a gathered relay before overall gathering completes and rejects a late host candidate', async () => {
  const relay = fixture({keepGathering: true, lateRelay: true});
  assert.equal((await relay.probe(config)).status, 'relay-nonce-delivered');
  assert.match(relay.peers[0].trickledCandidate.candidate, /typ relay$/);
  const late = fixture({keepGathering: true, lateHost: true});
  assert.equal((await late.probe(config)).status, 'relay-policy-escaped');
});

test('reports an exchange timeout after both relay descriptions were gathered', async () => {
  const {probe, peers} = fixture({stallExchange: true});
  assert.equal((await probe(config)).status, 'timeout-exchange');
  assert.ok(peers.every(peer => peer.closed));
});

test('rejects non-relay SDP, unverified selected pairs and a wrong reply', async () => {
  for (const [options, status] of [
    [{candidate: 'host'}, 'relay-candidate-missing'],
    [{selected: 'host'}, 'relay-pair-unverified-local-candidate'],
    [{corrupt: true}, 'nonce-mismatch'],
  ]) {
    const {probe, peers} = fixture(options);
    assert.equal((await probe(config)).status, status);
    assert.ok(peers.every(peer => peer.closed));
  }
});

test('refuses external or UDP TURN before creating peers', async () => {
  const {probe, peers} = fixture();
  for (const url of [
    'turn:external.example:51000?transport=tcp',
    'turn:127.0.0.1:51000?transport=udp',
    'turn:127.0.0.1:65536?transport=tcp',
  ]) assert.equal((await probe({...config, url})).status, 'fixture-invalid');
  assert.equal(peers.length, 0);
});


test('relay qualification rejects constructor or setter policy bypass', async () => {
  const challenge = {...config, challengeRelayPolicy: true};
  for (const options of [{}, {forceRelay: true, forceOnUpdate: false}]) {
    const {probe, peers} = fixture(options);
    assert.equal((await probe(challenge)).status, 'relay-policy-escaped');
    assert.ok(peers.every(peer => peer.closed));
  }
  const {probe, peers} = fixture({forceRelay: true});
  assert.equal((await probe(challenge)).status, 'relay-nonce-delivered');
  assert.deepEqual(peers.map(peer => peer.constructorPolicy), ['all', undefined]);
  assert.deepEqual(peers.map(peer => peer.updatedPolicy), ['all', undefined]);
});
