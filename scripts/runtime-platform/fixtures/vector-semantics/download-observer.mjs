// Actual browser download evidence for two owned loopback URLs only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export const ownedDownloadPayload=Buffer.from(Array.from({length:4096},(_,i)=>(i*31+7)%256));
export const ownedDownloadSHA256=crypto.createHash('sha256').update(ownedDownloadPayload).digest('hex');

export function verifyDownloads(data){
 const issues=[];
 if(data?.kind!=='actual-browser-download-operations')return ['missing download evidence'];
 const complete=data.complete,cancel=data.cancel;
 if(complete?.beginObserved!==true||complete.state!=='completed'||complete.totalBytes!==4096||complete.receivedBytes!==4096||complete.fileBytes!==4096||complete.fileSHA256!==ownedDownloadSHA256)issues.push('actual completed file missing or wrong');
 if(cancel?.beginObserved!==true||cancel.state!=='canceled'||cancel.cancelAcknowledged!==true||cancel.finalFileExists!==false||cancel.totalBytes!==1024*1024||!Number.isFinite(cancel.receivedBytes)||cancel.receivedBytes>=cancel.totalBytes)issues.push('actual cancellation missing or wrong');
 if(data.errors?.length||!Array.isArray(data.errors))issues.push('download observer errors');
 return issues;
}

export class OwnedDownloadObserver{
 constructor(browser,command,origin,root){
  this.browser=browser;this.command=command;this.origin=origin;
  this.dir=path.join(root,'owned-downloads');fs.mkdirSync(this.dir,{mode:0o700});
  this.rows=new Map();this.guids=new Map();this.errors=[];this.pending=new Set();
  this.listener=e=>{try{this.event(JSON.parse(e.data));}catch{this.errors.push('invalid-event');}};
  browser.addEventListener('message',this.listener);
 }
 async start(){await this.command(this.browser,'Browser.setDownloadBehavior',{behavior:'allowAndName',downloadPath:this.dir,eventsEnabled:true});}
 event(event){
  if(event.method==='Browser.downloadWillBegin'){
   const p=event.params,u=new URL(p.url);
   if(u.origin!==this.origin||u.pathname!=='/own-download')return;
   const name=u.searchParams.get('case');
   if(!['complete','cancel'].includes(name)||this.rows.has(name)||!/^[0-9a-f-]{36}$/.test(p.guid)){this.errors.push('unexpected-begin');return;}
   const row={beginObserved:true,guid:p.guid,state:'inProgress'};
   this.rows.set(name,row);this.guids.set(p.guid,name);
   if(name==='cancel'){
    const action=this.command(this.browser,'Browser.cancelDownload',{guid:p.guid}).then(()=>{row.cancelAcknowledged=true;}).catch(()=>{this.errors.push('cancel-refused');});
    this.pending.add(action);action.finally(()=>this.pending.delete(action));
   }
  }
  if(event.method==='Browser.downloadProgress'){
   const p=event.params,name=this.guids.get(p.guid);if(!name)return;
   const row=this.rows.get(name);
   // Terminal observations cannot revert to inProgress or change outcome.
   if(row.state!=='inProgress'&&p.state!==row.state){this.errors.push('terminal-state-changed');return;}
   if(!['inProgress','completed','canceled'].includes(p.state)){this.errors.push('unknown-state');return;}
   row.state=p.state;row.totalBytes=p.totalBytes;row.receivedBytes=p.receivedBytes;
  }
 }
 async receipt(name){
  const row=this.rows.get(name);
  if(!row||row.state==='inProgress')return {pending:true};
  await Promise.allSettled([...this.pending]);
  // allowAndName writes the browser-assigned GUID, never an arbitrary path
  // supplied by a page or suggestedFilename.
  const file=path.join(this.dir,row.guid),exists=fs.existsSync(file);
  const receipt={beginObserved:row.beginObserved,state:row.state,totalBytes:row.totalBytes,receivedBytes:row.receivedBytes};
  if(name==='complete'){
   if(!exists)return {pending:true};
   const stat=fs.lstatSync(file);assert(stat.isFile()&&!stat.isSymbolicLink()&&stat.size<=8192);
   const bytes=fs.readFileSync(file);receipt.fileBytes=bytes.length;receipt.fileSHA256=crypto.createHash('sha256').update(bytes).digest('hex');
  }else{receipt.cancelAcknowledged=row.cancelAcknowledged===true;receipt.finalFileExists=exists;}
  return {...receipt,observerErrors:[...this.errors]};
 }
 dispose(){this.browser.removeEventListener('message',this.listener);}
}

if(process.argv[2]==='--self-test'){
 const good={kind:'actual-browser-download-operations',complete:{beginObserved:true,state:'completed',totalBytes:4096,receivedBytes:4096,fileBytes:4096,fileSHA256:ownedDownloadSHA256},cancel:{beginObserved:true,state:'canceled',cancelAcknowledged:true,finalFileExists:false,totalBytes:1024*1024,receivedBytes:1024},errors:[]};
 assert.deepEqual(verifyDownloads(good),[]);
 const mutations=[x=>delete x.complete,x=>x.complete.fileSHA256='0'.repeat(64),x=>x.complete.receivedBytes=4095,x=>x.complete.beginObserved=false,x=>x.complete.state='inProgress',x=>delete x.cancel,x=>x.cancel.state='completed',x=>x.cancel.cancelAcknowledged=false,x=>x.cancel.finalFileExists=true,x=>x.cancel.receivedBytes=1024*1024,x=>x.errors.push('error')];
 for(const mutate of mutations){const copy=structuredClone(good);mutate(copy);assert(verifyDownloads(copy).length);}
 console.log(JSON.stringify({positiveControls:1,negativeControls:mutations.length,actualBrowser:false}));
}
