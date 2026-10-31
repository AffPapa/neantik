import assert from 'node:assert/strict';
import {PassThrough} from 'node:stream';
import {WebRTCBoundaryPipe,DOCUMENT_READY,PREFERENCE_READ,EXTENSION_READ,WEBRTC_PROBE} from './webrtc-boundary-pipe.mjs';
import {PREF_KEYS} from './webrtc-boundary-semantics.mjs';
const origin='http://127.0.0.1:12345',extension='chrome-extension://'+'a'.repeat(32);
const input=new PassThrough(),output=new PassThrough(),pipe=new WebRTCBoundaryPipe(input,output,origin,extension);
let url=origin+'/',wrongFrame=false,exception=false;
input.on('data',raw=>{
  const q=JSON.parse(raw.toString().replace(/\0$/,''));
  const result=q.method==='Page.getFrameTree'?{frameTree:{frame:{id:wrongFrame?'foreign':'frame',url}}}
    :q.method==='Runtime.evaluate'?{result:{value:{ok:true}},...(exception?{exceptionDetails:{text:'fixture failure'}}:{})}:{};
  output.write(JSON.stringify({id:q.id,result})+'\0');
});
pipe.pages.add('page');pipe.targets.add('page');pipe.sessions.set('session','page');
const created=(id=7,isDefault=true)=>({method:'Runtime.executionContextCreated',sessionId:'session',params:{context:{id,origin:url.startsWith('chrome://')?'chrome://prefs-internals':url.startsWith(extension)?extension:origin,auxData:{isDefault,frameId:'frame'}}}});
const params=expression=>({expression,contextId:7,awaitPromise:true,returnByValue:true});
let positive=0,negative=0;
const refused=fn=>{assert.throws(fn);negative++;};
for(const next of [origin+'/',...PREF_KEYS.map(key=>'chrome://prefs-internals/'+key),extension+'/probe.html']){
  url=next;await pipe.command('Page.navigate',{url},'session');pipe.observe(created());
  const allowed=url===origin+'/'?[DOCUMENT_READY,WEBRTC_PROBE]:url.startsWith(extension)?[EXTENSION_READ]:[PREFERENCE_READ];
  for(const expression of allowed){await pipe.evaluate(expression,'session');positive++;}
  for(const expression of ['arbitrary()',...([DOCUMENT_READY,PREFERENCE_READ,EXTENSION_READ,WEBRTC_PROBE].filter(x=>!allowed.includes(x)))])refused(()=>pipe.validate('Runtime.evaluate',params(expression),'session'));
  refused(()=>pipe.validate('Runtime.evaluate',{...params(allowed[0]),contextId:8},'session'));
  refused(()=>pipe.validate('Runtime.evaluate',{...params(allowed[0]),awaitPromise:false},'session'));
  refused(()=>pipe.validate('Runtime.evaluate',{...params(allowed[0]),extra:true},'session'));
}
for(const foreign of ['chrome://prefs-internals/','chrome://settings/','https://example.invalid/',origin+'/foreign',extension+'/other.html'])refused(()=>pipe.validate('Page.navigate',{url:foreign},'session'));
refused(()=>pipe.validate('Runtime.evaluate',params(EXTENSION_READ),'unknown'));
exception=true;await assert.rejects(pipe.evaluate(EXTENSION_READ,'session'));negative++;exception=false;
wrongFrame=true;await assert.rejects(pipe.evaluate(EXTENSION_READ,'session'));negative++;wrongFrame=false;
pipe.observe({method:'Runtime.executionContextsCleared',sessionId:'session',params:{}});
refused(()=>pipe.validate('Runtime.evaluate',params(EXTENSION_READ),'session'));
pipe.observe(created(7,false));refused(()=>pipe.validate('Runtime.evaluate',params(EXTENSION_READ),'session'));
pipe.close();
console.log(JSON.stringify({status:'webrtc-fixed-pipe-controls-pass',positive,negative,actualBrowser:false}));
