const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const path=require('node:path');
async function run(action, failure=false){
  const created=[], nodes=new Map();let claims=0, cleared=false;
  const make=tag=>({tag,children:[],listeners:{},value:'',append(...c){this.children.push(...c);},prepend(){},setAttribute(){},addEventListener(k,v){this.listeners[k]=v;},showModal(){this.open=true;},close(){this.open=false;},remove(){this.removed=true;},focus(){}});
  const node=id=>{if(!nodes.has(id))nodes.set(id,make(id));return nodes.get(id);};
  const storage={getItem(){return null;},setItem(){},removeItem(){}};
  const context={document:{body:{dataset:{cloud:'true'},append(){}},getElementById:node,querySelector:node,createElement(tag){const n=make(tag);created.push(n);return n;}},window:{localStorage:storage,initAccountSettings(){}},sessionStorage:{...storage,getItem(k){return k==='gamenight_pair'&&!cleared?'ticket':null;},removeItem(k){if(k==='gamenight_pair')cleared=true;}},location:{hash:'',pathname:'/studio',replace(){}},history:{replaceState(){}},URLSearchParams,Date,setTimeout(){},clearTimeout(){},fetch:async url=>{
    let data={},status=200;
    if(url==='/v1/me')data={id:'test'};
    if(url==='/v1/pairing/ticket')data={seat:1};
    if(url==='/v1/rooms/status')data={status:claims&&!failure?'connected':'none',room_code:'ABC234'};
    if(url==='/v1/pairing/claim'){claims++;if(failure)status=500;}
    return {status,ok:status<400,json:async()=>data};
  }};
  await vm.runInNewContext(readFileSync(path.join(__dirname,'../web/storage.js'),'utf8'),context);
  const dialog=created.find(n=>n.tag==='dialog'), panel=dialog.children[0];
  const [close,title,text,accept]=panel.children;
  assert.equal(dialog.open,true);assert.equal(accept.disabled,false);
  if(action==='cancel'){close.onclick();assert.equal(claims,0);assert.equal(cleared,true);assert.equal(dialog.removed,true);}
  else {
    await accept.onclick();assert.equal(claims,1);
    if(failure){assert.equal(dialog.open,true);assert.equal(accept.disabled,false);assert.equal(close.disabled,false);assert.equal(cleared,false);}
    else {assert.equal(dialog.removed,true);assert.equal(cleared,true);assert.equal(node('room-leave').hidden,false);}
  }
}
(async()=>{await run('cancel');await run('accept');await run('accept',true);console.log('Pairing dialog: cancel, accept and recoverable failure passed.');})().catch(e=>{console.error(e);process.exitCode=1;});
