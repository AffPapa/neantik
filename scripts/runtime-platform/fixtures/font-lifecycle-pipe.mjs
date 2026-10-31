// Research-only successor. Fixed nonce observation, no arbitrary JS execution.
// The existing navigation/auth pipe and its frozen receipts remain unchanged.
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
const keys=(value,expected)=>assert.deepEqual(Object.keys(value).sort(),expected.slice().sort(),'Unexpected lifecycle command fields');
const id=value=>assert(typeof value==='string'&&/^[A-Za-z0-9_.:-]{1,128}$/.test(value),'Invalid lifecycle identifier');
export class FontLifecyclePipe extends EventEmitter {
  constructor(input,output,origins,timeout=10000) {
    super();assert(origins.length===2&&origins.every(x=>/^http:\/\/(127\.0\.0\.1|localhost):[0-9]+$/.test(x)));
    this.input=input;this.output=output;this.origins=origins;this.timeout=timeout;
    this.sequence=0;this.buffer=Buffer.alloc(0);this.pending=new Map();this.closed=false;
    this.pages=new Set();this.frames=new Set();this.targets=new Set();this.sessions=new Map();this.contexts=new Map();this.versions=new Set();this.navigatedPages=new Set();this.retired=new Set();
    output.on('data',data=>this.receive(data));for(const event of ['end','error'])output.on(event,()=>this.close());input.on('error',()=>this.close());
  }
  own(url){return typeof url==='string'&&this.origins.some(origin=>url.startsWith(origin+'/'));}
  revokeTarget(target) {
    this.frames.delete(target);this.targets.delete(target);this.pages.delete(target);this.retired.add(target);
    for(const [session,owner] of this.sessions)if(owner===target){this.sessions.delete(session);this.contexts.delete(session);}
  }
  observe(item) {
    const p=item.params??{};
    if(['Target.targetCreated','Target.targetInfoChanged'].includes(item.method)) {
      const t=p.targetInfo;
      if(this.own(t?.url)&&!this.retired.has(t.targetId)){this.targets.add(t.targetId);if(t.type==='iframe')this.frames.add(t.targetId);if(this.pages.has(t.targetId))this.navigatedPages.add(t.targetId);}
      else if(t&&this.targets.has(t.targetId)&&!(this.pages.has(t.targetId)&&!this.navigatedPages.has(t.targetId)&&t.url==='about:blank'))this.revokeTarget(t.targetId);
    }
    if(item.method==='Target.attachedToTarget'&&this.own(p.targetInfo?.url)&&!this.retired.has(p.targetInfo.targetId)) {this.targets.add(p.targetInfo.targetId);if(p.targetInfo.type==='iframe')this.frames.add(p.targetInfo.targetId);this.sessions.set(p.sessionId,p.targetInfo.targetId);}
    if(item.method==='Target.detachedFromTarget'){this.sessions.delete(p.sessionId);this.contexts.delete(p.sessionId);}
    if(item.method==='Target.targetDestroyed')this.revokeTarget(p.targetId);
    if(item.method==='Runtime.executionContextCreated'&&this.sessions.has(item.sessionId)) {
      const set=this.contexts.get(item.sessionId)??new Set();set.add(p.context.id);this.contexts.set(item.sessionId,set);
    }
    if(item.method==='Runtime.executionContextDestroyed')this.contexts.get(item.sessionId)?.delete(p.executionContextId);
    if(item.method==='Runtime.executionContextsCleared')this.contexts.delete(item.sessionId);
    if(item.method==='ServiceWorker.workerVersionUpdated')for(const v of p.versions)if(this.own(v.scriptURL))this.versions.add(v.versionId);
  }
  validate(method,params,session) {
    const frameRead=method==='Page.getFrameTree';
    const pageMethod=['Page.enable','ServiceWorker.enable','ServiceWorker.stopWorker','Target.setAutoAttach','Page.navigate'].includes(method);
    if(session){id(session);assert(this.sessions.has(session),'Unknown owned session');}
    if(frameRead)assert(session&&(this.pages.has(this.sessions.get(session))||this.frames.has(this.sessions.get(session))),'Owned page/frame session required');
    if(pageMethod){assert(session&&this.pages.has(this.sessions.get(session)),'Owned page session required');}
    if(['Browser.getVersion','Browser.close'].includes(method)){keys(params,[]);assert.equal(session,null);return;}
    if(method==='Target.createTarget'){keys(params,['url']);assert.equal(params.url,'about:blank');assert.equal(session,null);return;}
    if(method==='Target.attachToTarget'){keys(params,['targetId','flatten']);id(params.targetId);assert(this.targets.has(params.targetId));assert.equal(params.flatten,true);assert.equal(session,null);return;}
    if(method==='Target.closeTarget'){keys(params,['targetId']);assert(this.pages.has(params.targetId));assert.equal(session,null);return;}
    if(method==='Target.setDiscoverTargets'){keys(params,['discover']);assert.equal(params.discover,true);assert.equal(session,null);return;}
    if(['Runtime.enable','Inspector.enable','Page.enable','Page.getFrameTree','ServiceWorker.enable'].includes(method)){keys(params,[]);assert(session);return;}
    if(method==='Target.setAutoAttach'){keys(params,['autoAttach','waitForDebuggerOnStart','flatten']);assert.equal(params.autoAttach,true);assert.equal(params.waitForDebuggerOnStart,false);assert.equal(params.flatten,true);return;}
    if(method==='Page.navigate'){keys(params,['url']);assert(this.own(params.url),'Navigation outside owned fixture');return;}
    if(method==='ServiceWorker.stopWorker'){keys(params,['versionId']);assert(this.versions.has(params.versionId),'Unknown owned service-worker version');return;}
    if(method==='Runtime.evaluate') {
      keys(params,['expression','contextId','returnByValue']);assert(session&&this.contexts.get(session)?.has(params.contextId),'Unknown owned context');
      assert.equal(params.expression,'globalThis.__OWN_REALM_NONCE??null');assert.equal(params.returnByValue,true);return;
    }
    assert.fail('Method outside font lifecycle scope');
  }
  command(method,params={},sessionId=null) {
    this.validate(method,params,sessionId);
    if(this.closed)return Promise.reject(Error('FontLifecyclePipeClosed'));
    return new Promise((resolve,reject)=>{
      const sequence=++this.sequence,timer=setTimeout(()=>{this.close();},this.timeout);
      this.pending.set(sequence,{method,params,sessionId,resolve,reject,timer});
      this.input.write(JSON.stringify({id:sequence,method,params,...(sessionId?{sessionId}:{})})+'\0');
    });
  }
  receive(data) {
    if(this.closed)return;this.buffer=Buffer.concat([this.buffer,data]);if(this.buffer.length>262144){this.close();return;}
    try {for(;;) {
      const end=this.buffer.indexOf(0);if(end<0)break;
      const bytes=this.buffer.subarray(0,end);this.buffer=this.buffer.subarray(end+1);if(!bytes.length)continue;
      const item=JSON.parse(bytes);assert(item&&typeof item==='object'&&!Array.isArray(item));
      if(Object.hasOwn(item,'id')) {
        const p=this.pending.get(item.id);assert(p,'Unsolicited lifecycle response');
        if(item.error){this.pending.delete(item.id);clearTimeout(p.timer);p.reject(Error('FontLifecycleCommandRefused'));continue;}
        if(p.method==='Target.createTarget'){id(item.result.targetId);this.pages.add(item.result.targetId);this.targets.add(item.result.targetId);}
        if(p.method==='Target.attachToTarget'){id(item.result.sessionId);this.sessions.set(item.result.sessionId,p.params.targetId);}
        this.pending.delete(item.id);clearTimeout(p.timer);
        p.resolve(item.result);
      }else {assert.equal(typeof item.method,'string');this.observe(item);this.emit('event',item);}
    }}catch{this.close();}
  }
  close(){if(this.closed)return;this.closed=true;for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(Error('FontLifecyclePipeClosed'));}this.pending.clear();this.buffer=Buffer.alloc(0);}
}
export function lifecycleSocketAdapter(pipe) {
  const listeners=new Map();
  return {addEventListener(type,listener){assert.equal(type,'message');assert(!listeners.has(listener));const callback=item=>listener({data:JSON.stringify(item)});listeners.set(listener,callback);pipe.on('event',callback);},
    removeEventListener(type,listener){assert.equal(type,'message');const callback=listeners.get(listener);if(callback){pipe.off('event',callback);listeners.delete(listener);}}};
}
