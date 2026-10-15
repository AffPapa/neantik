// Own font operations only. No installed-font inventory or fonts.check claims.
globalThis.runOwnFontPolicyRealm = async function({nonce, fontURL, ahemURL}) {
  const windowRealm = typeof document === 'object';
  const canvasAvailable = typeof OffscreenCanvas === 'function';
  const fontSet = windowRealm ? document.fonts : globalThis.fonts;
  const result = {kind:'own-font-policy-realm', nonce, realm:windowRealm?'page':'worker',
    available:{canvas:canvasAvailable, fontFace:typeof FontFace==='function', fontSet:!!fontSet, dom:windowRealm},
    local:[], resources:[], measurements:[], errors:[]};
  const retained=[];let stage='initialization';
  const bounded = async promise => {
    let timer;
    try {return await Promise.race([promise,new Promise((_,fail)=>timer=setTimeout(()=>fail(Error('OwnFontTimeout')),5000))]);}
    finally {clearTimeout(timer);}
  };
  async function face(family, source, kind) {
    const entry={kind,family,loaded:false,error:null,timedOut:false};
    try {
      const font=new FontFace(family,source);
      const loading=font.load();
      fontSet.add(font);retained.push(font);
      await bounded(loading);entry.loaded=font.status==='loaded';
    } catch(error) {entry.error=error.name;entry.timedOut=error.message==='OwnFontTimeout';}
    return entry;
  }
  async function capture(family, fallback, style, text, matched=false) {
    const canvas=new OffscreenCanvas(320,56), context=canvas.getContext('2d',{willReadFrequently:true});
    if(!context)throw Error('Canvas2DUnavailable');
    const font=`${style} 20px "${family}", ${fallback}`;
    context.font=font;
    if(matched)Object.assign(context,{fontKerning:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'});
    const typography={fontKerning:context.fontKerning,textRendering:context.textRendering,letterSpacing:context.letterSpacing,wordSpacing:context.wordSpacing};
    const widths=Array.from({length:3},()=>context.measureText(text).width);
    const pieces=text.match(/\S+| +/g);
    const wordBoundary=text.includes(' ')?{canvasPieces:pieces.map(piece=>context.measureText(piece).width),domPieces:null}:null;
    context.fillText(text,2,36);
    const pixels=context.getImageData(0,0,320,56).data;
    const mask=new Uint8Array(320*56);let ink=0;
    for(let i=0;i<mask.length;i++){mask[i]=pixels[i*4+3]>=128?1:0;ink+=mask[i];}
    const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',mask));
    const entry={widths,inkPixels:ink,typography,wordBoundary,
      maskSHA256:Array.from(hash,x=>x.toString(16).padStart(2,'0')).join(''),domWidths:null};
    if(windowRealm) {
      const element=document.createElement('span');
      element.textContent=text;
      Object.assign(element.style,{position:'fixed',left:'0',top:'0',whiteSpace:'pre',font,visibility:'hidden',width:'max-content'});
      if(matched)Object.assign(element.style,{fontKerning:'none',fontVariantLigatures:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'});
      document.body.append(element);
      try {
        entry.domWidths=Array.from({length:3},()=>element.getBoundingClientRect().width);
        const computed=getComputedStyle(element);
        entry.domTypography=Object.fromEntries(['fontKerning','fontVariantLigatures','textRendering','letterSpacing','wordSpacing'].map(key=>[key,computed[key]]));
        if(wordBoundary) {
          // Separate inline blocks cannot shape across their boundaries. Keep
          // these diagnostics apart from the whole-string DOM measurement.
          element.replaceChildren(...pieces.map(piece=>{const part=document.createElement('span');part.style.display='inline-block';part.textContent=piece;return part;}));
          wordBoundary.domPieces=Array.from(element.children,part=>part.getBoundingClientRect().width);
        }
      }
      finally {element.remove();}
    }
    return entry;
  }
  async function measure(family,fallback,style,text) {
    // Default Canvas and DOM may shape across spaces differently. Preserve
    // those observations; the equality gate uses explicit no-kerning settings.
    const native=await capture(family,fallback,style,text);
    const matched=await capture(family,fallback,style,text,true);
    result.measurements.push({family,fallback,style,text,...native,matched});
  }
  try {
    if(!canvasAvailable||!fontSet||typeof FontFace!=='function')return result;
    // A fresh Chromium worker FontFaceSet.ready starts pending until a load
    // cycle schedules its done event. Do not deadlock before starting a load.
    stage='initial-document-ready';if(windowRealm)await bounded(fontSet.ready);
    stage='local-font-loads';
    result.local.push(await face('QALocalUnique','local("NeAntikFontPolicyCanary")','known-own-unique'));
    result.local.push(await face('QALocalMissing',`local("NeAntikMissing_${nonce}")`,'invented-missing'));
    stage='downloaded-font-loads';
    for(const [family,url] of [['QARemoteCanary',fontURL],['QARemoteAhem',ahemURL]]) {
      const response=await bounded(fetch(url,{cache:'no-store'}));
      if(!response.ok)throw Error('OwnFontResourceHTTP');
      const bytes=await bounded(response.arrayBuffer());
      const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',bytes));
      // URL loading creates a real asynchronous FontFaceSet load cycle in the
      // worker; its immutable loopback bytes are independently hashed above.
      const entry=await face(family,`url(${JSON.stringify(url)})`,'downloaded-resource');
      result.resources.push({...entry,bytes:bytes.byteLength,sha256:Array.from(hash,x=>x.toString(16).padStart(2,'0')).join('')});
    }
    stage='fontset-ready-after-loads';await bounded(fontSet.ready);result.fontSetReadyAfterLoads=true;
    stage='font-measurements';
    for(const family of ['NeAntikFontPolicyCanary','Helvetica',`NeAntikMissing_${nonce}`])
      for(const fallback of ['monospace','serif'])
        for(const style of ['normal 400','normal 700','italic 400'])
          for(const text of ['ABABA','A B A B'])await measure(family,fallback,style,text);
    for(const family of ['QALocalUnique','QARemoteCanary','QARemoteAhem'])
      for(const fallback of ['monospace','serif'])await measure(family,fallback,'normal 400','ABABA');
  } catch(error) {result.errors.push({stage,kind:error.message==='OwnFontTimeout'?'timeout':error.name});}
  finally {
    for(const font of retained)fontSet.delete(font);
    result.ownFontFacesRemoved=retained.every(font=>!fontSet.has(font));
  }
  return result;
};
