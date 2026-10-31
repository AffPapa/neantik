// Bounded single-face parsing. Raw font bytes/tables stay inside the page.
globalThis.readOwnFontSFNT=function(bytes,expectedPostscriptName) {
  if(!(bytes instanceof Uint8Array)||bytes.length<28||bytes.length>32*1024*1024)throw Error('OwnFontSize');
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),tag=String.fromCharCode(...bytes.subarray(0,4));
  if(view.getUint32(0)!==0x00010000&&!['OTTO','true','typ1'].includes(tag))throw Error('OwnFontSignature');
  const count=view.getUint16(4),directoryEnd=12+count*16,tables=new Map(),ranges=[];
  if(count<1||count>256||directoryEnd>bytes.length)throw Error('OwnFontDirectory');
  for(let i=0;i<count;i++){
    const p=12+i*16,name=String.fromCharCode(...bytes.subarray(p,p+4)),offset=view.getUint32(p+8),length=view.getUint32(p+12);
    if(tables.has(name)||offset<directoryEnd||offset%4!==0||offset+length>bytes.length)throw Error('OwnFontTableBounds');
    tables.set(name,bytes.subarray(offset,offset+length));if(length)ranges.push([offset,offset+length]);
  }
  ranges.sort((a,b)=>a[0]-b[0]);for(let i=1;i<ranges.length;i++)if(ranges[i][0]<ranges[i-1][1])throw Error('OwnFontTableOverlap');
  const name=tables.get('name');if(!name||name.length<6)throw Error('OwnFontNameTable');
  const names=new DataView(name.buffer,name.byteOffset,name.byteLength),records=names.getUint16(2),strings=names.getUint16(4);
  if(records>4096||6+records*12>name.length||strings<6+records*12||strings>name.length)throw Error('OwnFontNameBounds');
  let matched=0;
  for(let i=0;i<records;i++){
    const p=6+i*12;if(names.getUint16(p+6)!==6)continue;
    const platform=names.getUint16(p),length=names.getUint16(p+8),start=strings+names.getUint16(p+10);
    if(start+length>name.length)throw Error('OwnFontNameBounds');
    if(![0,1,3].includes(platform))continue;
    const data=name.subarray(start,start+length);let text='';
    if(platform===1){if(data.some(x=>x>127))throw Error('OwnFontPostscriptEncoding');text=String.fromCharCode(...data);}
    else{if(length%2)throw Error('OwnFontPostscriptEncoding');for(let j=0;j<length;j+=2)text+=String.fromCharCode((data[j]<<8)|data[j+1]);}
    if(text!==expectedPostscriptName)throw Error('OwnFontPostscriptMismatch');matched++;
  }
  if(!matched)throw Error('OwnFontPostscriptMissing');
  return {tables,tableCount:count,validSFNT:true,expectedPostscriptName:true};
};
