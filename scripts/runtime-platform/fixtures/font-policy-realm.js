// Own font operations only. No installed-font inventory or fonts.check claims.
globalThis.runOwnFontPolicyRealm = async function({nonce, fontURL, ahemURL}) {
  const windowRealm = typeof document === 'object';
  const canvasAvailable = typeof OffscreenCanvas === 'function';
  const fontSet = windowRealm ? document.fonts : globalThis.fonts;
  const result = {kind:'own-font-policy-realm', nonce, realm:windowRealm?'page':'worker',
    available:{canvas:canvasAvailable, fontFace:typeof FontFace==='function', fontSet:!!fontSet, dom:windowRealm},
    local:[], resources:[], measurements:[], errors:[]};
  const retained=[];
  const bounded = async promise => {
    let timer;
    try {return await Promise.race([promise,new Promise((_,fail)=>timer=setTimeout(()=>fail(Error('OwnFontTimeout')),5000))]);}
    finally {clearTimeout(timer);}
  };
  async function face(family, source, kind) {
    const entry={kind,family,loaded:false,error:null,timedOut:false};
    try {
      const font=new FontFace(family,source);
      await bounded(font.load());
      fontSet.add(font);retained.push(font);entry.loaded=font.status==='loaded';
    } catch(error) {entry.error=error.name;entry.timedOut=error.message==='OwnFontTimeout';}
    return entry;
  }
  async function measure(family, fallback, style, text) {
    const canvas=new OffscreenCanvas(320,56), context=canvas.getContext('2d',{willReadFrequently:true});
    if(!context)throw Error('Canvas2DUnavailable');
    const font=`${style} 20px "${family}", ${fallback}`;
    context.font=font;
    const widths=Array.from({length:3},()=>context.measureText(text).width);
    context.fillText(text,2,36);
    const pixels=context.getImageData(0,0,320,56).data;
    const mask=new Uint8Array(320*56);let ink=0;
    for(let i=0;i<mask.length;i++){mask[i]=pixels[i*4+3]>=128?1:0;ink+=mask[i];}
    const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',mask));
    const entry={family,fallback,style,text,widths,inkPixels:ink,
      maskSHA256:Array.from(hash,x=>x.toString(16).padStart(2,'0')).join(''),domWidths:null};
    if(windowRealm) {
      const element=document.createElement('span');
      element.textContent=text;
      Object.assign(element.style,{position:'fixed',left:'0',top:'0',whiteSpace:'pre',font,visibility:'hidden',width:'max-content'});
      document.body.append(element);
      try {entry.domWidths=Array.from({length:3},()=>element.getBoundingClientRect().width);}
      finally {element.remove();}
    }
    result.measurements.push(entry);
  }
  try {
    if(!canvasAvailable||!fontSet||typeof FontFace!=='function')return result;
    await bounded(fontSet.ready);
    result.local.push(await face('QALocalUnique','local("NeAntikFontPolicyCanary")','known-own-unique'));
    result.local.push(await face('QALocalMissing',`local("NeAntikMissing_${nonce}")`,'invented-missing'));
    for(const [family,url] of [['QARemoteCanary',fontURL],['QARemoteAhem',ahemURL]]) {
      const response=await bounded(fetch(url,{cache:'no-store'}));
      if(!response.ok)throw Error('OwnFontResourceHTTP');
      const bytes=await bounded(response.arrayBuffer());
      const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',bytes));
      const entry=await face(family,bytes,'downloaded-resource');
      result.resources.push({...entry,bytes:bytes.byteLength,sha256:Array.from(hash,x=>x.toString(16).padStart(2,'0')).join('')});
    }
    await bounded(fontSet.ready);
    for(const family of ['NeAntikFontPolicyCanary','Helvetica',`NeAntikMissing_${nonce}`])
      for(const fallback of ['monospace','serif'])
        for(const style of ['normal 400','normal 700','italic 400'])
          for(const text of ['ABABA','A B A B'])await measure(family,fallback,style,text);
    for(const family of ['QALocalUnique','QARemoteCanary','QARemoteAhem'])
      for(const fallback of ['monospace','serif'])await measure(family,fallback,'normal 400','ABABA');
  } catch(error) {result.errors.push(error.name);}
  finally {
    for(const font of retained)fontSet.delete(font);
    result.ownFontFacesRemoved=retained.every(font=>!fontSet.has(font));
  }
  return result;
};
