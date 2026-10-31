import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import {OwnedSTUN6Fixture,bindingRequest,bindingResponse6,verifyResponse6} from './webrtc-stun6-fixture.mjs';
const transaction=Buffer.from('0102030405060708090a0b0c','hex'),request=bindingRequest(transaction),reply=bindingResponse6(request,12345);verifyResponse6(reply,transaction,12345);
let negatives=0;
for(const mutate of [b=>b.subarray(0,19),b=>{b[0]=2;return b;},b=>{b[2]=1;return b;},b=>{b[4]=0;return b;}]){assert.throws(()=>bindingResponse6(mutate(Buffer.from(request)),12345));negatives++;}
for(const mutate of [b=>b.subarray(0,43),b=>{b[25]=1;return b;},b=>{b[28]^=1;return b;},b=>{b[40]^=1;return b;},b=>{b[26]^=1;return b;},b=>{b[8]^=1;return b;}]){assert.throws(()=>verifyResponse6(mutate(Buffer.from(reply)),transaction,12345));negatives++;}
const server=await new OwnedSTUN6Fixture().start();
try{const canary=await server.verifyAndReset();assert(canary.canaryAcknowledged&&server.browserRequests===0);const client=dgram.createSocket({type:'udp6',ipv6Only:true});try{await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('OwnUDP6ControlTimeout')),1500);client.once('message',bytes=>{try{verifyResponse6(bytes,transaction,client.address().port);clearTimeout(timer);resolve();}catch(e){clearTimeout(timer);reject(e);}});client.send(request,server.port,'::1');});}finally{client.close();}const final=await server.close();assert.equal(final.browserRequests,1);assert.equal(final.canaryCount,1);assert.equal(final.invalidRequests,0);}finally{await server.close();}
console.log(JSON.stringify({status:'owned-udp6-controls-pass',positive:3,negative:negatives,realLoopbackUDP6:true,actualBrowser:false}));
