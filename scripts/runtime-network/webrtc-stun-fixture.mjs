// Minimal owned UDP4 STUN binding responder; no raw ICE/address export.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import dgram from 'node:dgram';

export function bindingRequest(transaction) {
  assert(Buffer.isBuffer(transaction) && transaction.length === 12);
  const request=Buffer.alloc(20);request.writeUInt16BE(1);request.writeUInt32BE(0x2112a442,4);transaction.copy(request,8);return request;
}
export function bindingResponse(packet,port) {
  assert(Buffer.isBuffer(packet) && packet.length >= 20 && packet.length <= 4096
    && packet.readUInt16BE(0) === 1 && packet.readUInt16BE(2) + 20 === packet.length
    && packet.readUInt16BE(2) % 4 === 0 && packet.readUInt32BE(4) === 0x2112a442);
  assert(Number.isInteger(port) && port > 0 && port < 65536);
  const out=Buffer.alloc(32);out.writeUInt16BE(0x101);out.writeUInt16BE(12,2);
  packet.copy(out,4,4,20);out.writeUInt16BE(0x20,20);out.writeUInt16BE(8,22);out[25]=1;
  out.writeUInt16BE(port^0x2112,26);out.writeUInt32BE((0x7f000001^0x2112a442)>>>0,28);return out;
}
export class OwnedSTUNFixture {
  constructor() {
    this.server=dgram.createSocket('udp4');this.canary=crypto.randomBytes(12);
    this.canaryCount=0;this.browserRequests=0;this.invalidRequests=0;this.measuring=false;this.closed=false;
    this.server.on('message',(packet,peer)=>{
      try {
        assert.equal(peer.address,'127.0.0.1');
        const response=bindingResponse(packet,peer.port);
        if(packet.subarray(8,20).equals(this.canary))this.canaryCount++;
        else {assert(this.measuring);this.browserRequests++;}
        this.server.send(response,peer.port,peer.address);
      } catch {this.invalidRequests++;}
    });
  }
  async start() {
    await new Promise((resolve,reject)=>{this.server.once('error',reject);this.server.bind(0,'127.0.0.1',resolve);});
    this.port=this.server.address().port;return this;
  }
  async verifyAndReset() {
    assert(!this.measuring && !this.closed);
    const client=dgram.createSocket('udp4');
    try {
      await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(Error('OwnedSTUNCanaryTimeout')),1500);
        client.once('error',error=>{clearTimeout(timer);reject(error);});
        client.once('message',(reply,peer)=>{
          try {
            assert.equal(peer.address,'127.0.0.1');assert.equal(peer.port,this.port);
            assert.equal(reply.length,32);assert.equal(reply.readUInt16BE(0),0x101);
            assert(reply.subarray(8,20).equals(this.canary));
            assert.equal(reply.readUInt16BE(26)^0x2112,client.address().port);
            clearTimeout(timer);resolve();
          } catch(error){clearTimeout(timer);reject(error);}
        });
        client.send(bindingRequest(this.canary),this.port,'127.0.0.1');
      });
      assert.equal(this.canaryCount,1);assert.equal(this.browserRequests,0);assert.equal(this.invalidRequests,0);
      this.browserRequests=0;this.measuring=true;
      return {canaryAcknowledged:true,canaryCount:this.canaryCount,resetVerified:true,countAfterReset:this.browserRequests};
    } finally {client.close();}
  }
  async close() {
    if(!this.closed){await new Promise(resolve=>this.server.close(resolve));this.closed=true;}
    return {browserRequests:this.browserRequests,invalidRequests:this.invalidRequests,canaryCount:this.canaryCount};
  }
}
