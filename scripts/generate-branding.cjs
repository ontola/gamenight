// web/icon.svg is the sole editable logo. Run with Sharp installed to regenerate.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),source='web/icon.svg',manifest='web/branding.json';
const digest=data=>crypto.createHash('sha256').update(data).digest('hex');
if(process.argv.includes('--check')){
  const record=JSON.parse(fs.readFileSync(path.join(root,manifest)));
  for(const [file,hash] of Object.entries(record.sha256)) if(digest(fs.readFileSync(path.join(root,file)))!==hash)throw Error('Regenerate branding: '+file);
  console.log('All branding assets match the single SVG source.');
}else{(async()=>{
  const sharp=require('sharp'),svg=fs.readFileSync(path.join(root,source)),hashes={[source]:digest(svg)};
  function write(file,data){fs.writeFileSync(path.join(root,file),data);hashes[file]=digest(data);}
  const png=await sharp(svg).resize(512,512).png().toBuffer();
  // Explorer and the taskbar read the small sizes; keep those as classic 32-bit BMP
  // frames and only compress the 256px frame, as Windows' own icons do.
  const bmp=async size=>{const raw=await sharp(svg).resize(size,size).ensureAlpha().raw().toBuffer(),mask=Math.ceil(size/32)*4*size;
    const frame=Buffer.alloc(40+size*size*4+mask);frame.writeUInt32LE(40,0);frame.writeInt32LE(size,4);frame.writeInt32LE(size*2,8);frame.writeUInt16LE(1,12);frame.writeUInt16LE(32,14);frame.writeUInt32LE(size*size*4+mask,20);
    for(let y=0;y<size;y++)for(let x=0;x<size;x++){const from=(y*size+x)*4,to=40+((size-1-y)*size+x)*4;frame[to]=raw[from+2];frame[to+1]=raw[from+1];frame[to+2]=raw[from];frame[to+3]=raw[from+3];}
    return frame;};
  const sizes=[16,24,32,48,64,256],frames=await Promise.all(sizes.map(size=>size<256?bmp(size):sharp(svg).resize(size,size).png().toBuffer()));
  const header=Buffer.alloc(6+16*sizes.length);header.writeUInt16LE(1,2);header.writeUInt16LE(sizes.length,4);
  let offset=header.length;frames.forEach((frame,i)=>{const at=6+i*16;header[at]=sizes[i]%256;header[at+1]=sizes[i]%256;header.writeUInt16LE(1,at+4);header.writeUInt16LE(32,at+6);header.writeUInt32LE(frame.length,at+8);header.writeUInt32LE(offset,at+12);offset+=frame.length;});
  const ico=Buffer.concat([header,...frames]);
  write('web/favicon.ico',ico);write('web/apple-touch-icon.png',await sharp(svg).resize(180,180).png().toBuffer());
  write('site/icon.svg',svg);write('mobile/assets/icon.svg',svg);write('site/icon.png',png);write('site/favicon.ico',ico);
  write('crates/lobby/branding/gamenight.ico',ico);write('lobbies/game-room/assets/gamenight.ico',ico);
  write('crates/lobby/branding/icon-64.rgba',await sharp(svg).resize(64,64).ensureAlpha().raw().toBuffer());
  fs.writeFileSync(path.join(root,manifest),JSON.stringify({source,sha256:hashes},null,2)+'\n');
})().catch(error=>{console.error(error);process.exit(1);});}
