// Offline supplement over retained native receipts;no browser launch or secrets.
import assert from 'node:assert/strict';
import {verifyWebRTCCase} from './webrtc-boundary-semantics.mjs';
export function verifyIPv6Pair(rows,binding){
 assert(Array.isArray(rows)&&rows.length===2);assert.deepEqual(rows.map(r=>r.id),['direct','guarded']);
 for(const row of rows){assert.equal(row.transport,'IPv6 loopback STUN');verifyWebRTCCase(row,binding);}
 // Collector traffic alone is insufficient:the real direct ICE context must
 // also obtain a server-reflexive candidate from its configured STUN server.
 assert(rows[0].probe.candidates.srflx>0,'Direct ICE did not confirm STUN success');
 assert.equal(rows[1].probe.candidates.srflx,0,'Guarded ICE obtained a STUN candidate');
 assert.deepEqual(rows[0].sourceSHA256,rows[1].sourceSHA256,'Producer changed across pair');
 const end=Date.parse(rows[0].finishedAt),start=Date.parse(rows[1].startedAt);assert(Number.isFinite(end)&&Number.isFinite(start)&&end<start,'Unordered lifecycle');
 return{status:'scoped-headed-ipv6-stun-pair-pass',cases:2,UDPRequests:rows.map(r=>r.udp.browserRequests),rawICEExported:false,globalNetworkQualified:false,releaseQualified:false,scope:'Own UDP6 loopback;actual direct STUN and guarded noUDP with HTTPproxy. Not OS policies,TURN,external interfaces,manager relay or WebKit.'};
}
