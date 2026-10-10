// Independent synthetic Web Platform fixtures; no third-party harness code.
(async () => {
 const bytes = a => {let s='';for(const b of a)s+=String.fromCharCode(b);return btoa(s);};
 const read=(c,x=0,y=0,w=c.width,h=c.height)=>bytes(c.getContext('2d').getImageData(x,y,w,h).data);
 const blob=async c=>{const b=await new Promise(ok=>c.toBlob(ok,'image/png'));if(!b)throw Error('toBlob unavailable');return bytes(new Uint8Array(await b.arrayBuffer()));};
 const make=(w,h)=>{const c=document.createElement('canvas');c.width=w;c.height=h;return c;};
 const result={schemaVersion:1,canvas:[],audio:[],errors:[]};
 for(const kind of ['solid','clear','black-alpha','grid']) {
  try {
   const c=make(32,24),ctx=c.getContext('2d');
   if(kind==='solid'){ctx.fillStyle='#2468ac';ctx.fillRect(0,0,32,24);}
   if(kind==='clear'){ctx.fillStyle='#2468ac';ctx.fillRect(0,0,32,24);ctx.clearRect(0,0,32,24);}
   if(kind==='black-alpha'||kind==='grid'){
    const d=ctx.createImageData(32,24);
    for(let y=0;y<24;y++)for(let x=0;x<32;x++){
     const i=(y*32+x)*4;
     d.data.set(kind==='black-alpha'?[0,0,0,128]:[(x*7+y*3)%256,(y*11+x)%256,(x*13+y*17)%256,255],i);
    }
    ctx.putImageData(d,0,0);
   }
   const full=read(c),repeat=read(c),crop=read(c,5,3,16,12),oob=read(c,-2,-2,36,28);
   const png=c.toDataURL('image/png').split(',')[1],pngBlob=await blob(c),after=read(c);
   c.width=32;ctx.fillStyle='#2468ac';ctx.fillRect(0,0,32,24);
   const reset=read(c);
   result.canvas.push({kind,width:32,height:24,full,repeat,crop,oob,png,pngBlob,after,reset});
  }catch(e){result.errors.push({vector:'canvas',kind,error:e.name});}
 }
 for(const offset of [null,0,0.5,-0.5,2,-2]){
  try {
   const channels=offset===null?2:1,length=offset===null?4096:1024;
   const run=async()=>{const c=new OfflineAudioContext(channels,length,44100);
    if(offset!==null){const src=new ConstantSourceNode(c,{offset});src.connect(c.destination);src.start(0);}
    const b=await c.startRendering();
    return {channels:b.numberOfChannels,length:b.length,sampleRate:b.sampleRate,
      buffers:Array.from({length:b.numberOfChannels},(_,i)=>{const a=b.getChannelData(i);return bytes(new Uint8Array(a.buffer,a.byteOffset,a.byteLength));})};};
   result.audio.push({offset,first:await run(),repeat:await run()});
  }catch(e){result.errors.push({vector:'audio',offset,error:e.name});}
 }
 return result;
})()
