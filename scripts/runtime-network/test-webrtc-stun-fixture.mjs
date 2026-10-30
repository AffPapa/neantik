import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import {OwnedSTUNFixture,bindingRequest,bindingResponse} from './webrtc-stun-fixture.mjs';
const transaction=Buffer.alloc(12,0x77),request=bindingRequest(transaction),response=bindingResponse(request,12345);
assert(response.subarray(8,20).equals(transaction));assert.equal(response.readUInt16BE(26)^0x2112,12345);
let negative=0;
for(const alter of [b=>b.subarray(0,19),b=>{b[0]=2;return b;},b=>{b[2]=1;return b;},b=>{b[4]=0;return b;}]) {
  const bad=alter(Buffer.from(request));assert.throws(()=>bindingResponse(bad,12345));negative++;
}
const server=await new OwnedSTUNFixture().start();
try {
  const control=await server.verifyAndReset();assert.equal(control.canaryAcknowledged,true);assert.equal(server.browserRequests,0);
  const client=dgram.createSocket('udp4');
  try {
    await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('OwnedUDPTestTimeout')),1500);
      client.once('message',reply=>{clearTimeout(timer);assert(reply.subarray(8,20).equals(transaction));resolve();});
      client.send(request,server.port,'127.0.0.1');});
  } finally {client.close();}
  const final=await server.close();assert.equal(final.browserRequests,1);assert.equal(final.canaryCount,1);assert.equal(final.invalidRequests,0);
} finally {await server.close();}
console.log(JSON.stringify({status:'owned-stun-fixture-controls-pass',realLoopbackUDP:true,positive:3,negative,actualBrowser:false}));
