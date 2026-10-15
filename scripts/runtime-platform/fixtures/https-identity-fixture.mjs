// Two ephemeral HTTPS origins plus an allowlisted loopback CONNECT proxy.
// Raw synthetic identity is private evidence. No ordinary system trust changes.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import http from 'node:http';
import net from 'node:net';
import {spawnSync} from 'node:child_process';
import {pageSource,workerSource,serviceWorkerSource,policyControlSource} from './https-identity-probe.mjs';

export const identityHeaders = Object.freeze(['user-agent','accept-language','sec-ch-ua','sec-ch-ua-mobile',
  'sec-ch-ua-platform','sec-ch-ua-arch','sec-ch-ua-bitness','sec-ch-ua-platform-version',
  'sec-ch-ua-full-version-list','sec-ch-device-memory','device-memory']);
const acceptCH = identityHeaders.filter(x=>!['user-agent','accept-language'].includes(x)).join(', ');
const listen = server => new Promise((resolve,reject)=>{
  server.once('error',reject);server.listen(0,'127.0.0.1',()=>{server.removeListener('error',reject);resolve();});
});

export function ownCertificate(root) {
  const certificate=path.join(root,'owned-certificate.pem'),key=path.join(root,'owned-key.pem'),config=path.join(root,'owned-certificate.cnf');
  fs.writeFileSync(config,'[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Owned NeAntik QA\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n',{mode:0o600,flag:'wx'});
  const result=spawnSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',config,'-keyout',key,'-out',certificate],{stdio:'ignore'});
  assert.equal(result.status,0,'Own certificate creation failed');fs.chmodSync(key,0o600);
  const cert=fs.readFileSync(certificate),publicKey=new crypto.X509Certificate(cert).publicKey.export({format:'der',type:'spki'});
  return {cert,key:fs.readFileSync(key),spki:crypto.createHash('sha256').update(publicKey).digest('base64'),keyPath:key};
}

export async function createIdentityFixture(root, {browserCustody=()=>null}={}) {
  const certificate=ownCertificate(root),sockets=new Set(),upstreamPorts=new Map();
  const entries=[],connects=[],denied=[];let active=null;let config;
  function track(socket){sockets.add(socket);socket.on('error',()=>{});socket.once('close',()=>sockets.delete(socket));}
  function handler(role,req,res) {
    const u=new URL(req.url,'https://localhost');
    res.setHeader('Cache-Control','no-store');
    if(!active||u.searchParams.get('token')!==active.token){res.writeHead(404);res.end();return;}
    const socket=req.socket,link=upstreamPorts.get(socket.remotePort);
    const record={id:crypto.randomUUID(),sessionID:active.id,role,path:u.pathname,
      operation:u.searchParams.get('operation'),nonce:u.searchParams.get('nonce'),
      tls:socket.encrypted===true,protocol:socket.getProtocol(),
      throughProxy:!!link&&link.role===role,connectID:link?.id??null,
      browserCustody:link?.browserCustody??null,
      directBrowserCustody:link?null:browserCustody(socket.remotePort,socket.localPort),
      headers:Object.fromEntries(identityHeaders.map(k=>[k,req.headers[k]??null]))};
    assert(entries.length<512,'Own request bound exceeded');entries.push(record);
    res.setHeader('Accept-CH',acceptCH);
    const policies=['ch-ua','ch-ua-mobile','ch-ua-platform','ch-ua-arch','ch-ua-bitness','ch-ua-platform-version','ch-ua-full-version-list','ch-device-memory'];
    res.setHeader('Permissions-Policy',policies.map(x=>u.pathname==='/policy-control'?`${x}=(self)`:`${x}=(self "${config.a}" "${config.b}")`).join(', '));
    if(req.headers.origin===config.a||req.headers.origin===config.b)res.setHeader('Access-Control-Allow-Origin',req.headers.origin);
    res.setHeader('Vary','Origin');res.setHeader('Access-Control-Allow-Methods','GET, POST, OPTIONS');res.setHeader('Access-Control-Allow-Headers','Content-Type, Accept-Language');
    if(req.method==='OPTIONS'){res.writeHead(204);res.end();return;}
    if(u.pathname==='/identity'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({receiptID:record.id,nonce:record.nonce,operation:record.operation,headers:record.headers}));return;}
    if(u.pathname==='/redirect'||u.pathname==='/cross-redirect'){
      res.writeHead(302,{Location:(u.pathname==='/redirect'?config.a:config.b)+'/identity'+u.search});res.end();return;
    }
    if(u.pathname==='/worker.js'||u.pathname==='/owned-sw.js'){
      res.setHeader('Content-Type','text/javascript');res.setHeader('Service-Worker-Allowed','/');
      res.end(u.pathname==='/worker.js'?workerSource({...config,token:active.token}):serviceWorkerSource({...config,token:active.token}));return;
    }
    if(u.pathname==='/result'&&req.method==='POST'){
      let body='',overflow=false;req.on('data',chunk=>{body+=chunk;if(body.length>65536){overflow=true;req.destroy();}});
      req.once('end',()=>{if(overflow)return;try{assert(active.result===null);active.result=JSON.parse(body);res.writeHead(204);res.end();}catch{res.writeHead(400);res.end();}});return;
    }
    if(u.pathname==='/warm'){
      res.setHeader('Content-Type','text/html');res.end('<!doctype html><script>parent.postMessage({ownWarm:'+JSON.stringify(active.token)+'},'+JSON.stringify(config.a)+')</script>');return;
    }
    if(u.pathname==='/policy-control'){
      res.setHeader('Content-Type','text/html');res.end('<!doctype html><script>'+policyControlSource({...config,token:active.token})+'</script>');return;
    }
    if(u.pathname==='/'){
      res.setHeader('Content-Type','text/html');res.end('<!doctype html><meta charset="utf-8"><title>Own HTTPS identity QA</title><body><script>'+pageSource({...config,token:active.token})+'</script>');return;
    }
    res.writeHead(404);res.end();
  }
  const a=https.createServer(certificate,(q,s)=>handler('a',q,s)),b=https.createServer(certificate,(q,s)=>handler('b',q,s));
  const proxy=http.createServer((_q,s)=>{s.writeHead(405);s.end();});
  for(const server of [a,b,proxy])server.on('connection',track);
  await listen(a);await listen(b);await listen(proxy);
  config={a:'https://127.0.0.1:'+a.address().port,b:'https://localhost:'+b.address().port};
  const destinations=new Map([[new URL(config.a).host,'a'],[new URL(config.b).host,'b']]);
  proxy.on('connect',(req,client,head)=>{
    const role=destinations.get(req.url);
    if(!active||!role){if(denied.length<512)denied.push({sessionID:active?.id??null,reason:'outside-owned-destinations'});client.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');return;}
    const custody=browserCustody(client.remotePort,proxy.address().port);
    const upstream=net.connect({host:'127.0.0.1',port:Number(new URL(config[role]).port)});track(upstream);
    const id=crypto.randomUUID();let port=null;
    upstream.once('connect',()=>{
      port=upstream.localPort;upstreamPorts.set(port,{id,role,browserCustody:custody});connects.push({id,role,sessionID:active.id,browserCustody:custody});
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');if(head.length)upstream.write(head);upstream.pipe(client);client.pipe(upstream);
    });
    upstream.once('close',()=>{if(port)upstreamPorts.delete(port);client.destroy();});
    client.once('close',()=>upstream.destroy());upstream.once('error',()=>client.destroy());
  });
  return {config,certificate,proxyPort:proxy.address().port,entries,connects,denied,
    begin(id){assert(!active||active.closed);active={id,token:crypto.randomBytes(24).toString('hex'),result:null,closed:false};return active;},
    finish(){assert(active);active.closed=true;return {result:active.result,receipts:entries.filter(x=>x.sessionID===active.id),connects:connects.filter(x=>x.sessionID===active.id),denied:denied.filter(x=>x.sessionID===active.id)};},
    async close(){
      const drained=Promise.all([...sockets].map(socket=>new Promise(resolve=>socket.once('close',resolve))));
      for(const socket of sockets)socket.destroy();
      let timer;try{await Promise.race([drained,new Promise((_resolve,reject)=>{timer=setTimeout(()=>reject(Error('Owned socket cleanup timeout')),3000);})]);}
      finally{clearTimeout(timer);}
      await Promise.all([a,b,proxy].map(s=>new Promise(resolve=>s.close(resolve))));
      assert.equal(sockets.size,0);fs.unlinkSync(certificate.keyPath);
    }
  };
}
