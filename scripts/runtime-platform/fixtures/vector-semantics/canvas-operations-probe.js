// Owned synthetic pixels only. The independent oracle recomputes expected
// geometry/colors; this producer never declares its own operations PASS.
(async () => {
 const result={schemaVersion:1,kind:'canvas-operations',cases:{},errors:[]};
 const colors=[[19,71,203,0],[19,71,203,1],[19,71,203,32],[240,120,36,64],
   [31,211,73,128],[200,61,19,192],[19,71,203,254],[19,71,203,255]];
 const make=(w=16,h=12)=>{const c=document.createElement('canvas');c.width=w;c.height=h;return c;};
 const context=c=>c.getContext('2d',{colorSpace:'srgb'});
 const read=c=>{let s='';for(const v of context(c).getImageData(0,0,c.width,c.height).data)s+=String.fromCharCode(v);return btoa(s);};
 const state=x=>({alpha:x.globalAlpha,composite:x.globalCompositeOperation,fill:x.fillStyle,
   lineWidth:x.lineWidth,shadowBlur:x.shadowBlur,smoothing:x.imageSmoothingEnabled,
   transform:Array.from(x.getTransform().toFloat64Array())});
 const image=x=>{const d=x.createImageData(16,12);for(let y=0;y<12;y++)for(let a=0;a<16;a++){
   d.data.set([(a*7+y*3)%256,(y*11+a)%256,(a*13+y*17)%256,255],(y*16+a)*4);
 }return d;};
 const capture=(name,operation)=>{try{result.cases[name]=operation();}catch(e){result.errors.push({operation:name,error:e.name});}};
 const source=make(),sx=context(source);sx.putImageData(image(sx),0,0);
 capture('putOpaque',()=>({pixels:read(source),repeat:read(source)}));
 capture('copyCanvas',()=>{const c=make(),x=context(c);x.drawImage(source,0,0);return{pixels:read(c),repeat:read(c)};});
 capture('copyCrop',()=>{const c=make(20,18),x=context(c);x.drawImage(source,3,2,4,5,5,7,4,5);return{pixels:read(c)};});
 capture('copyComposite',()=>{const c=make(),x=context(c);x.fillStyle='#ff00ff';x.fillRect(0,0,16,12);
   // A partial transparent source distinguishes copy from source-over:
   // copy replaces alpha and clears destination pixels outside the source.
   const partial=make(8,6),p=context(partial),d=p.createImageData(8,6);
   for(let y=0;y<6;y++)for(let a=0;a<8;a++)if((a+y)%2===0)
     d.data.set([(a*7+y*3)%256,(y*11+a)%256,(a*13+y*17)%256,255],(y*8+a)*4);
   p.putImageData(d,0,0);x.globalCompositeOperation='copy';x.drawImage(partial,2,3);return{pixels:read(c)};});
 capture('putClipped',()=>{const c=make(),x=context(c);x.putImageData(image(x),-3,-2,2,1,8,7);return{pixels:read(c)};});
 capture('coloredPut',()=>{const c=make(),x=context(c),d=x.createImageData(16,12);
   for(let y=0;y<12;y++)for(let a=0;a<16;a++)d.data.set(colors[(a+y)%colors.length],(y*16+a)*4);
   x.putImageData(d,0,0);return{pixels:read(c),repeat:read(c)};});
 capture('sourceOver',()=>{const c=make(),x=context(c);x.fillStyle=`rgba(23,44,111,${128/255})`;x.fillRect(0,0,16,12);
   x.fillStyle=`rgba(212,75,13,${64/255})`;x.fillRect(0,0,16,12);return{pixels:read(c),repeat:read(c)};});
 capture('reset',()=>{const c=make(),x=context(c);if(typeof x.reset!=='function')return{available:false};
   // Prove clearing against nonzero pixels before mutating clip/state.
   x.putImageData(image(x),0,0);const beforeReset=read(c);
   // restore() after reset must not resurrect the pre-reset saved stack.
   x.globalAlpha=.6;x.fillStyle='#abcdef';x.save();x.translate(5,7);x.globalAlpha=.2;x.globalCompositeOperation='xor';x.lineWidth=9;
   x.fillStyle='#123456';x.shadowBlur=5;x.imageSmoothingEnabled=false;
   x.beginPath();x.rect(5,5,1,1);x.clip();x.fillRect(0,0,16,12);
   x.reset();x.restore();const blank=read(c),defaults=state(x);x.fillRect(0,0,2,2);
   return{available:true,beforeReset,blank,state:defaults,afterFill:read(c)};});
 for(const dimension of ['Width','Height'])capture('resize'+dimension,()=>{
   const c=make(),x=context(c);x.putImageData(image(x),0,0);x.globalAlpha=.31;x.translate(3,4);
   x.fillStyle='#123456';x.globalCompositeOperation='copy';x.save();
   c[dimension.toLowerCase()]=dimension==='Width'?17:13;x.restore();
   return{width:c.width,height:c.height,pixels:read(c),state:state(x)};
 });
 capture('errors',()=>{const c=make(),x=context(c),names={};
   for(const [name,call] of [['zeroRead',()=>x.getImageData(0,0,0,1)],
     ['zeroImage',()=>x.createImageData(0,1)],['invalidPut',()=>x.putImageData(null,0,0)]]){
    try{call();names[name]='no-error';}catch(e){names[name]=e.name;}
   }return names;
 });
 return result;
})()
