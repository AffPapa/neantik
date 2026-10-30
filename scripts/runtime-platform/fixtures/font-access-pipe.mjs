// Separate permission seam. The previous font/lifecycle pipe remains frozen.
import assert from 'node:assert/strict';
import {FontLifecyclePipe} from './font-lifecycle-pipe.mjs';
const keys=(value,list)=>assert.deepEqual(Object.keys(value).sort(),list.slice().sort());
export class FontAccessPipe extends FontLifecyclePipe {
  #scope=null;#confirmed=null;#generation=0;#topContexts=new Map();#primaryTarget=null;
  constructor(input,output,origins,nonce,timeout=10000){super(input,output,origins,timeout);assert(/^[a-f0-9]{32}$/.test(nonce));this.nonce=nonce;this.pageURL=origins[0]+'/access?nonce='+nonce;this.foreignPageURL=origins[1]+'/top-foreign?nonce='+nonce;}
  observe(item){
    const p=item.params??{},session=item.sessionId??p.sessionId,pageId=this.sessions.get(session),target=p.targetId??p.targetInfo?.targetId,ownSession=this.pages.has(pageId)&&(!this.#primaryTarget||pageId===this.#primaryTarget),ownTarget=this.pages.has(target)&&(!this.#primaryTarget||target===this.#primaryTarget);
    const changed=(item.method==='Target.targetInfoChanged'&&ownTarget&&p.targetInfo.url!==this.pageURL)||
      (item.method==='Page.frameNavigated'&&ownSession&&!p.frame?.parentId)||
      (['Runtime.executionContextsCleared','Target.detachedFromTarget'].includes(item.method)&&ownSession)||
      (item.method==='Runtime.executionContextDestroyed'&&ownSession&&this.#topContexts.get(session)?.id===p.executionContextId)||
      (item.method==='Target.targetDestroyed'&&ownTarget);
    if(changed){this.#generation++;this.#scope=null;this.#confirmed=null;if(session)this.#topContexts.delete(session);else this.#topContexts.clear();}
    super.observe(item);
    if(item.method==='Runtime.executionContextCreated'&&this.pages.has(this.sessions.get(item.sessionId))&&(!this.#primaryTarget||this.sessions.get(item.sessionId)===this.#primaryTarget)){
      const c=p.context;
      if(c.auxData?.isDefault===true&&c.auxData.frameId===this.sessions.get(item.sessionId)&&c.origin===this.origins[0]){
        assert(typeof c.uniqueId==='string'&&c.uniqueId.length>0&&c.uniqueId.length<=256);
        this.#generation++;this.#scope=null;this.#confirmed=null;this.#topContexts.set(item.sessionId,{...c});
      }
    }
  }
  #live(scope){const c=this.#topContexts.get(scope?.sessionId);return !this.closed&&scope?.generation===this.#generation&&this.pages.has(scope.targetId)&&this.sessions.get(scope.sessionId)===scope.targetId&&c?.id===scope.contextId&&c?.uniqueId===scope.uniqueId;}
  validate(method,params,session){
    if(method==='Target.getTargetInfo'){
      keys(params,['targetId']);assert.equal(session,null);assert(this.pages.has(params.targetId));return;
    }
    if(method==='Page.navigate'){
      const target=this.sessions.get(session);assert(this.pages.has(target));
      if(params.url===this.pageURL)assert(!this.#primaryTarget||this.#primaryTarget===target);
      else{assert.equal(params.url,this.foreignPageURL);assert(this.#primaryTarget&&target!==this.#primaryTarget&&this.#live(this.#scope));}
    }
    if(method==='Target.activateTarget'){keys(params,['targetId']);assert.equal(session,null);assert(this.pages.has(params.targetId));return;}
    if(method==='Browser.setPermission'){
      keys(params,['permission','setting','origin','embeddedOrigin','browserContextId']);keys(params.permission,['name']);
      assert.equal(session,null);assert.equal(params.permission.name,'local-fonts');assert(['denied','granted'].includes(params.setting));
      assert.equal(params.origin,this.origins[0]);assert.equal(params.embeddedOrigin,this.origins[0]);
      const scope=this.#scope;assert(scope&&this.#confirmed===scope&&this.#live(scope),'Live nonce-confirmed permission scope required');
      assert.equal(params.browserContextId,scope.browserContextId);return;
    }
    if(method==='Runtime.evaluate')assert(this.#scope&&this.#live(this.#scope)&&session===this.#scope.sessionId&&params.contextId===this.#scope.contextId,'Exact live default page context required');
    return super.validate(method,params,session);
  }
  async command(method,params={},sessionId=null){
    if(method==='Page.navigate'&&params.url===this.pageURL){this.validate(method,params,sessionId);this.#primaryTarget=this.sessions.get(sessionId);}
    const generation=this.#generation,scope=this.#scope;
    const result=await super.command(method,params,sessionId);
    if(['Target.getTargetInfo','Runtime.evaluate','Browser.setPermission'].includes(method))assert(!this.closed&&this.#generation===generation,'Stale Font Access authority response');
    if(method==='Target.getTargetInfo'){
      const t=result.targetInfo;assert.equal(t?.targetId,params.targetId);assert.equal(t.type,'page');
      assert(typeof t.browserContextId==='string'&&/^[A-Za-z0-9_.:-]{1,128}$/.test(t.browserContextId));
      if(this.#primaryTarget&&t.targetId!==this.#primaryTarget){assert(this.#scope===scope&&this.#live(scope));assert.equal(t.url,this.foreignPageURL);assert.equal(t.browserContextId,scope.browserContextId);return result;}
      assert.equal(t.url,this.pageURL);this.#primaryTarget=t.targetId;
      assert(this.pages.has(t.targetId));const session=[...this.sessions].find(([s,id])=>id===t.targetId&&this.#topContexts.has(s))?.[0];assert(session,'Observed default page context required');
      const context=this.#topContexts.get(session);assert(this.contexts.get(session)?.has(context.id));
      this.#scope={targetId:t.targetId,sessionId:session,browserContextId:t.browserContextId,contextId:context.id,uniqueId:context.uniqueId,generation};this.#confirmed=null;
    }
    if(['Runtime.evaluate','Browser.setPermission'].includes(method))assert(this.#scope===scope&&this.#live(scope),'Revoked Font Access authority response');
    if(method==='Runtime.evaluate'){assert.equal(result.result?.value,this.nonce);this.#confirmed=scope;}
    return result;
  }
  async scopedPermission(setting){assert(this.#scope);return this.command('Browser.setPermission',{permission:{name:'local-fonts'},setting,origin:this.origins[0],embeddedOrigin:this.origins[0],browserContextId:this.#scope.browserContextId});}
  close(){this.#generation++;this.#scope=null;this.#confirmed=null;super.close();}
}
