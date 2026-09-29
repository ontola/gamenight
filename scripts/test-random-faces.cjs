const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const source=fs.readFileSync(path.resolve(__dirname,'../web/studio.js'),'utf8');
const recipes=source.slice(source.indexOf('    const INK ='),source.indexOf('    // Never hand out the same face'));
const normalize=source.slice(source.indexOf('    function normalizeFace('),source.indexOf('    function decodeAvatar('));
let values=[],index=0;const math=Object.create(Math);math.random=()=>values[index++%values.length];
const context={Math:math};vm.createContext(context);
vm.runInContext(`const EMPTY=null,GRID_SIZE=48,HEAD={x:24,y:28,radius:12};${normalize}${recipes};globalThis.api={FACE_RECIPES,dressRandomFace,normalizeFace};`,context);
const {FACE_RECIPES,dressRandomFace,normalizeFace}=context.api;
for(const recipe of FACE_RECIPES){
 const bare=recipe.build();assert.equal(bare.length,2304);
 for(let i=0;i<bare.length;i++)if(bare[i]!==null){const x=i%48+.5-24,y=Math.floor(i/48)+.5-28;assert.ok(x*x+y*y<=156.25,`${recipe.name} has a facial feature outside its head at ${i%48},${Math.floor(i/48)}`);}
 const occupied=bare.map((color,i)=>color===null?null:i%48).filter(x=>x!==null);
 assert.ok(occupied.reduce((a,b)=>a+b,0)/occupied.length>26,`${recipe.name} lost its facing direction`);
 for(let style=0;style<8;style++){
  values=[.1,.5,(style+.1)/8];index=0;const dressed=dressRandomFace(bare.slice());assert.equal(dressed.length,2304);
  for(let i=0;i<bare.length;i++)if(bare[i]!==null)assert.equal(dressed[i],bare[i],`${recipe.name}/${style} covers the face`);
 }
}
// A saved legacy drawing keeps its established coordinates, not the new preset placement.
const legacy=Array(256).fill(null);legacy[0]='#123456';
assert.equal(normalizeFace(legacy)[23*48+22],'#123456');
const saved=Array(2304).fill(null);saved[900]='#123456';assert.deepEqual([...normalizeFace(saved)],saved);
console.log('PASS 12 expressions × 8 headwear styles keep their facing direction and fitted hats; saved drawings preserve their positions.');
