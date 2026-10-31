// Actual loopback TLS/CONNECT tests; these qualify the fixture, not a browser.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import tls from 'node:tls';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import {once} from 'node:events';
import {createIdentityFixture} from './https-identity-fixture.mjs';
import {pageSource,workerSource,serviceWorkerSource,policyControlSource} from './https-identity-probe.mjs';

const root=fs.mkdtempSync(path.join(os.tmpdir(),'neantik-owned-https-test-'));fs.chmodSync(root,0o700);
let fixture;
const head=socket=>new Promise((resolve,reject)=>{
  let data=Buffer.alloc(0);const timer=setTimeout(()=>{socket.destroy();reject(Error('header-timeout'));},3000);
  const receive=chunk=>{data=Buffer.concat([data,chunk]);if(data.length>16384){clearTimeout(timer);socket.destroy();reject(Error('header-bound'));return;}
    const end=data.indexOf('\r\n\r\n');if(end!==-1){clearTimeout(timer);socket.removeListener('data',receive);resolve(data.subarray(0,end).toString());}};
  socket.on('data',receive);socket.once('error',reject);
});
try{
  fixture=await createIdentityFixture(root,{browserCustody:()=>({sameProcessGroup:true,runtimePathBound:true,generationSHA256:'a'.repeat(64)})});
  const state=fixture.begin('owned-protocol-control'),config={...fixture.config,token:state.token};
  for(const source of [pageSource,workerSource,serviceWorkerSource,policyControlSource])new vm.Script(source(config));
  const destination=new URL(fixture.config.a);
  async function request(proxied){
    let plain;
    if(proxied){plain=net.connect({host:'127.0.0.1',port:fixture.proxyPort});await once(plain,'connect');const response=head(plain);plain.write('CONNECT '+destination.host+' HTTP/1.1\r\nHost: '+destination.host+'\r\n\r\n');assert((await response).startsWith('HTTP/1.1 200'));}
    const socket=tls.connect({...proxied?{socket:plain}:{host:'127.0.0.1',port:Number(destination.port)},servername:'localhost',ca:fixture.certificate.cert});
    await once(socket,'secureConnect');assert(socket.authorized);let data='';socket.on('data',chunk=>{data+=chunk;assert(data.length<65536);});
    socket.write('GET /identity?token='+state.token+'&operation=page&nonce='+String(proxied)+' HTTP/1.1\r\nHost: '+destination.host+'\r\nConnection: close\r\n\r\n');
    await once(socket,'end');socket.destroy();assert(data.startsWith('HTTP/1.1 200'));return data;
  }
  await request(true);await request(false);
  const rows=fixture.entries.filter(x=>x.path==='/identity');assert.equal(rows.length,2);
  assert(rows[0].tls&&rows[0].throughProxy&&rows[0].connectID&&rows[0].browserCustody.sameProcessGroup);
  assert(rows[1].tls&&!rows[1].throughProxy&&rows[1].connectID===null);
  const denied=net.connect({host:'127.0.0.1',port:fixture.proxyPort});await once(denied,'connect');const deniedHead=head(denied);denied.write('CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n');assert((await deniedHead).startsWith('HTTP/1.1 403'));denied.destroy();
  assert.equal(fixture.denied.length,1);assert.equal(fixture.connects.length,1);
  fixture.finish();await fixture.close();assert(!fs.existsSync(path.join(root,'owned-key.pem')));fixture=null;
  console.log(JSON.stringify({status:'pass',actualBrowser:false,actualTLS:true,throughCONNECT:true,DirectClassifiedSeparately:true,externalDestinationDenied:true,scriptsCompiled:4,keyRemoved:true}));
}finally{if(fixture)await fixture.close();fs.rmSync(root,{recursive:true,force:true});}
