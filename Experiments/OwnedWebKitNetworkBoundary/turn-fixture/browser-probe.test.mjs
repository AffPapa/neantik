import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {runInNewContext} from 'node:vm';

const source = readFileSync(new URL('./browser-probe.js', import.meta.url), 'utf8');
const config = {url: 'turn:synthetic.invalid:51000?transport=tcp', username: 'qa', credential: 'synthetic'};

function fixture({candidate = 'relay', selected = 'relay', corrupt = false} = {}) {
  const peers = [];
  class Peer {
    constructor(options) {
      assert.equal(options.iceTransportPolicy, 'relay');
      assert.equal(options.iceServers.length, 1);
      assert.equal(options.iceServers[0].urls, config.url);
      peers.push(this);
    }
    createDataChannel() {
      this.channel = {};
      return this.channel;
    }
    async createOffer() { return {type: 'offer'}; }
    async createAnswer() { return {type: 'answer'}; }
    async setLocalDescription({type}) {
      this.localDescription = {type, sdp: 'a=candidate:synthetic 1 UDP 1 ignored 1 typ ' + candidate + '\r\n'};
      this.iceGatheringState = 'complete';
    }
    async setRemoteDescription({type}) {
      if (type !== 'answer') return;
      const incoming = {send: data => this.channel.onmessage({data: corrupt ? 'mismatch' : data})};
      peers[1].ondatachannel({channel: incoming});
      this.channel.send = data => incoming.onmessage({data});
      this.channel.onopen();
    }
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
    RTCPeerConnection: Peer, crypto: webcrypto, isSecureContext: true, setTimeout, clearTimeout,
  });
  return {probe, peers};
}

test('reports a bidirectional nonce and two selected relay pairs without exporting signaling', async () => {
  const {probe, peers} = fixture();
  assert.equal(JSON.stringify(await probe(config)), '{"status":"relay-nonce-delivered"}');
  assert.equal(peers.length, 2);
  assert.ok(peers.every(peer => peer.closed));
});

test('rejects non-relay SDP, unverified selected pairs and a wrong reply', async () => {
  for (const [options, status] of [
    [{candidate: 'host'}, 'relay-candidate-missing'],
    [{selected: 'host'}, 'relay-pair-unverified'],
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
