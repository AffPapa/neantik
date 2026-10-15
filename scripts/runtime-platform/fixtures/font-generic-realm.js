// Explicit CSS generic operations, with no installed-font enumeration.
globalThis.runOwnGenericFontRealm=async function(nonce) {
  const output=[];
  for(const generic of ['standard','serif','monospace','sans-serif','cursive','fantasy','math'])
    for(const style of ['normal 400','normal 700','italic 400'])for(const text of ['ABABA','A B A B']) {
      const canvas=new OffscreenCanvas(320,56),context=canvas.getContext('2d',{willReadFrequently:true});
      if(!context)throw Error('OwnGenericCanvasUnavailable');
      const family=generic==='standard'?`"NeAntikMissing_${nonce}"`:generic;
      context.font=`${style} 20px ${family}`;
      Object.assign(context,{fontKerning:'none',textRendering:'optimizeSpeed',letterSpacing:'0px',wordSpacing:'0px'});
      const appliedFont=context.font;
      const typography=Object.fromEntries(['fontKerning','textRendering','letterSpacing','wordSpacing'].map(key=>[key,context[key]]));
      const widths=Array.from({length:3},()=>context.measureText(text).width);context.fillText(text,2,36);
      const pixels=context.getImageData(0,0,320,56).data,mask=new Uint8Array(320*56);let inkPixels=0;
      for(let i=0;i<mask.length;i++){mask[i]=pixels[i*4+3]>=128?1:0;inkPixels+=mask[i];}
      const bytes=new Uint8Array(await crypto.subtle.digest('SHA-256',mask));
      output.push({generic,style,text,appliedFont,typography,widths,inkPixels,maskSHA256:Array.from(bytes,x=>x.toString(16).padStart(2,'0')).join('')});
    }
  return output;
};
