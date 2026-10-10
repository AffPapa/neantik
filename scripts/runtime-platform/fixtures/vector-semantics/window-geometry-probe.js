(async () => {
 const frame = () => new Promise(ok => requestAnimationFrame(() => requestAnimationFrame(ok)));
 const rect = r => Object.fromEntries(['x','y','left','top','right','bottom','width','height'].map(k => [k,r[k]]));
 const host = document.createElement('div');
 host.style.cssText='position:relative;width:1600px;height:12000px;margin:0;padding:0';
 document.documentElement.style.cssText='margin:0;padding:0;scroll-behavior:auto'; document.body.style.margin='0';
 const box=document.createElement('div');box.style.cssText='position:absolute;left:101px;top:8000px;width:203px;height:37px;box-sizing:border-box';host.append(box);
 const textBox=document.createElement('div');textBox.style.cssText='position:absolute;left:41px;top:160px;font:16px/24px monospace;white-space:pre;width:400px';
 const span=document.createElement('span'),first=document.createTextNode('Own ASCII 012345'),second=document.createTextNode('Second line 6789');
 span.append(first,document.createElement('br'),second);textBox.append(span);host.append(textBox);document.body.append(host);
 let resizeEvents=0,fullscreenEvents=0;addEventListener('resize',()=>resizeEvents++);document.addEventListener('fullscreenchange',()=>fullscreenEvents++);
 const rangeValue = r => ({bounding:rect(r.getBoundingClientRect()),clients:Array.from(r.getClientRects(),rect)});
 function ranges(){
  const all=document.createRange();all.selectNodeContents(span);
  const line1=document.createRange();line1.selectNodeContents(first);
  const line2=document.createRange();line2.selectNodeContents(second);
  const caret=document.createRange();caret.setStart(first,4);caret.collapse(true);
  return {all:rangeValue(all),line1:rangeValue(line1),line2:rangeValue(line2),caret:rangeValue(caret),span:{bounding:rect(span.getBoundingClientRect()),clients:Array.from(span.getClientRects(),rect)}};
 }
 function boxValue(){const r=document.createRange();r.selectNode(box);return {bounding:rect(box.getBoundingClientRect()),client:rect(box.getClientRects()[0]),range:rangeValue(r),scrollX,scrollY};}
 async function sample(){
  await frame();scrollTo(0,0);box.style.transform='';await frame();const before=boxValue(),textBefore=ranges();
  scrollTo(20,6000);await frame();const after=boxValue();box.style.transform='translate(32px,16px)';await frame();const translated=boxValue();
  box.style.transform='';scrollTo(0,0);await frame();
  const repeat=ranges(),c=document.createElement('canvas').getContext('2d');c.font='16px monospace';
  const widths=[c.measureText('Own ASCII 012345').width,c.measureText('Own ASCII 012345').width];
  return {kind:'window-geometry-sample',before,after,translated,textBefore,textRepeat:repeat,textWidths:widths,screen:{width:screen.width,height:screen.height,availWidth:screen.availWidth,availHeight:screen.availHeight,availLeft:screen.availLeft,availTop:screen.availTop,colorDepth:screen.colorDepth,pixelDepth:screen.pixelDepth},viewport:{innerWidth,innerHeight,outerWidth,outerHeight,dpr:devicePixelRatio,clientWidth:document.documentElement.clientWidth,scrollbarWidth:innerWidth-document.documentElement.clientWidth,visualViewport:{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}},widthMediaIntegerTolerance:0.5,media:{dpr:matchMedia('(resolution: '+devicePixelRatio+'dppx)').matches,width:matchMedia('(min-width: '+(innerWidth-0.5)+'px) and (max-width: '+(innerWidth+0.5)+'px)').matches,screenWidth:matchMedia('(device-width: '+screen.width+'px)').matches},resizeEvents,fullscreenEvents,fullscreen:document.fullscreenElement===document.documentElement};
 }
 globalThis.OWN_WINDOW_SAMPLE=sample;
 globalThis.OWN_ENTER_FULLSCREEN=async()=>{await document.documentElement.requestFullscreen();return await sample();};
 globalThis.OWN_EXIT_FULLSCREEN=async()=>{await document.exitFullscreen();return await sample();};
 return await sample();
})()
