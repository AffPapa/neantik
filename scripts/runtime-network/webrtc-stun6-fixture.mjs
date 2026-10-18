// Independent owned UDP6 STUN collector. Never records peer IPs or raw ICE.
// XOR-MAPPED-ADDRESS IPv6 uses the cookie AND transaction ID (RFC8489§14.2).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import dgram from 'node:dgram';
import {bindingRequest} from './webrtc-stun-fixture.mjs';
export {bindingRequest};
export function bindingResponse6(packet,port){
 assert(Buffer.isBuffer(packet)&&packet.length>=20&&packet.length<=4096&&packet.readUInt16BE(0)===1&&packet.readUInt16BE(2)+20===packet.length&&packet.readUInt16BE(2)%4===0&&packet.readUInt32BE(4)===0x2112a442);
 assert(Number.isInteger(port)&&port>0&&port<65536);
 const out=Buffer.alloc(44);out.writeUInt16BE(0x101);out.writeUInt16BE(24,2);packet.copy(out,4,4,20);out.writeUInt16BE(0x20,20);out.writeUInt16BE(20,22);out[25]=2;out.writeUInt16BE(port^0x2112,26);
 for(let i=0;i<16;i++)out[28+i]=packet[4+i]^(i===15?1:0);return out;
}
export function verifyResponse6(reply,transaction,port){
 assert(Buffer.isBuffer(reply)&&reply.length===44&&reply.readUInt16BE(0)===0x101&&reply.readUInt16BE(2)===24&&reply.readUInt32BE(4)===0x2112a442&&reply.subarray(8,20).equals(transaction));
 assert(reply.readUInt16BE(20)===0x20&&reply.readUInt16BE(22)===20&&reply[24]===0&&reply[25]===2&&(reply.readUInt16BE(26)^0x2112)===port);
 for(let i=0;i<16;i++)assert.equal(reply[28+i]^reply[4+i],i===15?1:0);
}
export class OwnedSTUN6Fixture{
 constructor(){
  this.server=dgram.createSocket({type:'udp6',ipv6Only:true});this.canary=crypto.randomBytes(12);this.canaryCount=0;this.browserRequests=0;this.invalidRequests=0;this.measuring=false;this.closed=false;
  this.server.on('message',(packet,peer)=>{try{assert.equal(peer.address,'::1');assert.equal(peer.family,'IPv6');const response=bindingResponse6(packet,peer.port);if(packet.subarray(8,20).equals(this.canary))this.canaryCount++;else{assert(this.measuring);this.browserRequests++;}this.server.send(response,peer.port,peer.address);}catch{this.invalidRequests++;}});
 }
 async start(){await new Promise((resolve,reject)=>{this.server.once('error',reject);this.server.bind(0,'::1',resolve);});this.port=this.server.address().port;return this;}
 async verifyAndReset(){
  assert(!this.measuring&&!this.closed);const client=dgram.createSocket({type:'udp6',ipv6Only:true});
  try{await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('OwnedUDP6CanaryTimeout')),1500);client.once('error',e=>{clearTimeout(timer);reject(e);});client.once('message',(reply,peer)=>{try{assert.equal(peer.address,'::1');assert.equal(peer.port,this.port);verifyResponse6(reply,this.canary,client.address().port);clearTimeout(timer);resolve();}catch(e){clearTimeout(timer);reject(e);}});client.send(bindingRequest(this.canary),this.port,'::1');});assert.equal(this.canaryCount,1);assert.equal(this.browserRequests,0);assert.equal(this.invalidRequests,0);this.measuring=true;return{canaryAcknowledged:true,canaryCount:1,resetVerified:true,countAfterReset:0};}finally{client.close();}
 }
 async close(){if(!this.closed){await new Promise(resolve=>this.server.close(resolve));this.closed=true;}return{browserRequests:this.browserRequests,invalidRequests:this.invalidRequests,canaryCount:this.canaryCount};}
}
