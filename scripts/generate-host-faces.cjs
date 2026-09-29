// Reuse the actual character editor recipes, rather than a second face style.
// Run from any directory: node scripts/generate-host-faces.cjs
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'..');
const source=fs.readFileSync(path.join(root,'web/studio.js'),'utf8');
const recipes=source.slice(source.indexOf("    const INK ="),source.indexOf('    // Never hand out the same face'));
const normalize=source.slice(source.indexOf('    function normalizeFace('),source.indexOf('    function decodeAvatar('));
if(!recipes||!normalize)throw Error('Character editor recipe boundaries changed');
const choices=[['Cheeky',[.1,.5,.8]],['Pirate',[.3,.2,.6]],['Surprised',[.8,.7,.99]],['Grin',[.7,.1,.3]]];
const faces=choices.map(([name,random])=>{
 let n=0;const math=Object.create(Math);math.random=()=>random[n++%random.length];
 const context={Math:math};vm.createContext(context);
 vm.runInContext(`const EMPTY=null,GRID_SIZE=48;${normalize}${recipes}\nglobalThis.pixels=dressRandomFace(FACE_RECIPES.find(r=>r.name===${JSON.stringify(name)}).build());`,context);
 const colors=new Map();
 for(let y=0;y<48;y++)for(let x=0;x<48;){const color=context.pixels[y*48+x];let end=x+1;while(end<48&&context.pixels[y*48+end]===color)end++;
  if(color)colors.set(color,(colors.get(color)||'')+`M${x} ${y}h${end-x}v1h-${end-x}z`);x=end;}
 const id=name.toLowerCase();
 return `<symbol id="host-face-${id}" viewBox="0 0 48 48"><circle cx="24" cy="28" r="12" fill="currentColor"/><g shape-rendering="crispEdges">${[...colors].map(([c,d])=>`<path fill="${c}" d="${d}"/>`).join('')}</g></symbol>\n`+
 `<symbol id="host-person-${id}" viewBox="0 0 48 64"><g fill="currentColor"><path d="M17 38h16l4 13-5 2-2-9v11H18V44l-2 9-5-2z"/><path d="M18 52h6v9h-8v-4h2zm8 0h6l3 9h-9z"/></g><path d="M16 60h8v3h-8zm10 0h10v3H26z" fill="#262439"/><use href="#host-face-${id}" width="48" height="48"/></symbol>`;
});
const file=path.join(root,'web/host.html'),html=fs.readFileSync(file,'utf8');
const marker=/<!-- HOST_FACES_START -->[\s\S]*?<!-- HOST_FACES_END -->/;
if(!marker.test(html))throw Error('Missing host face markers');
fs.writeFileSync(file,html.replace(marker,`<!-- HOST_FACES_START -->\n<svg class="host-face-defs" aria-hidden="true" focusable="false"><defs>\n${faces.join('\n')}\n</defs></svg>\n<!-- HOST_FACES_END -->`));
console.log('Generated four consistent host-guide faces from the editor recipes.');
