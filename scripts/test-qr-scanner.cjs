const vm=require('node:vm'),assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');const path=require('node:path');
async function run(native){
  const nodes=new Map(),draws=[];let scans=0,opened=null,reloads=0;
  const node=id=>{if(!nodes.has(id))nodes.set(id,{open:true,hidden:true,close(){this.open=false;},querySelector(){return {after(){}};},addEventListener(){},getBoundingClientRect(){return {left:0,top:0,right:400,bottom:600};}});return nodes.get(id);};
  const canvas={getContext(){return {drawImage(...args){draws.push(args.slice(1));},getImageData(){return {data:new Uint8ClampedArray(4),width:canvas.width,height:canvas.height};}};}};
  class TestURL extends URL {static createObjectURL(){return 'blob:test';}static revokeObjectURL(){}}
  const context={document:{getElementById:node,createElement(){return canvas;},addEventListener(){}},window:{location:{origin:"https://gamenight.ontola.io",pathname:"/studio",search:"",assign(url){opened=url;},reload(){reloads++;}},addEventListener(){},jsQR(){scans++;return scans===2?{data:'https://gamenight.ontola.io/studio#pair=test'}:null;}},location:{hash:""},URL:TestURL,Image:class{naturalWidth=3840;naturalHeight=2160;async decode(){}},navigator:{},setTimeout(){},clearTimeout(){}};
  if(native)context.window.BarcodeDetector=class{static async getSupportedFormats(){return ['qr_code'];}async detect(){return [{rawValue:'https://gamenight.ontola.io/studio#pair=test'}];}};
  vm.runInNewContext(readFileSync(path.join(__dirname,'../web/qr-scanner.js'),'utf8'),context);
  const event={target:{files:[{}],value:'photo'}};await node('qr-photo').onchange(event);
  assert.equal(node('qr-result').hidden,true);assert.equal(opened,'https://gamenight.ontola.io/studio#pair=test');assert.equal(reloads,1);assert.equal(node('qr-scanner').open,false);assert.equal(event.target.value,'');
  if(native)assert.equal(scans,0);
  else {assert.equal(scans,2);assert.deepEqual(draws[0].slice(0,4),[0,0,3840,2160]);assert.equal(draws[0][6],1600);assert.equal(draws[1][2],2304);}
}
(async()=>{await run(false);await run(true);console.log('QR scanner: full-frame high resolution, detailed crop fallback and native detection passed.');})().catch(e=>{console.error(e);process.exitCode=1;});
