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
  const sizes=[16,32,48,64,128,256],frames=await Promise.all(sizes.map(size=>sharp(svg).resize(size,size).png().toBuffer()));
  const header=Buffer.alloc(6+16*sizes.length);header.writeUInt16LE(1,2);header.writeUInt16LE(sizes.length,4);
  let offset=header.length;frames.forEach((frame,i)=>{const at=6+i*16;header[at]=sizes[i]%256;header[at+1]=sizes[i]%256;header.writeUInt16LE(1,at+4);header.writeUInt16LE(32,at+6);header.writeUInt32LE(frame.length,at+8);header.writeUInt32LE(offset,at+12);offset+=frame.length;});
  const ico=Buffer.concat([header,...frames]);
  write('web/favicon.ico',ico);write('web/apple-touch-icon.png',await sharp(svg).resize(180,180).png().toBuffer());
  write('site/icon.svg',svg);write('site/icon.png',png);write('site/favicon.ico',ico);
  write('crates/lobby/branding/gamenight.ico',ico);
  write('crates/lobby/branding/icon-64.rgba',await sharp(svg).resize(64,64).ensureAlpha().raw().toBuffer());
  fs.writeFileSync(path.join(root,manifest),JSON.stringify({source,sha256:hashes},null,2)+'\n');
})().catch(error=>{console.error(error);process.exit(1);});}
