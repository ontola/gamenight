const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const path=require('node:path');
(async()=>{
  const nodes=new Map();
  function node(id){if(!nodes.has(id))nodes.set(id,{children:Array.from({length:6},()=>({textContent: ""})),hidden:false,disabled:false,textContent:'',listeners:{},addEventListener(n,fn){this.listeners[n]=fn;},append(){},prepend(){},setAttribute(){}});return nodes.get(id);}
  let state={status:'connected',room_code:'ABC234'}, poll, failLeave=false, joins=0, failJoin=false;
  const storage={getItem(){return null;},setItem(){},removeItem(){}};
  const context={document:{body:{dataset:{cloud:'true'},append(){}},getElementById:node,querySelector:node,createElement:()=>node('new')},window:{localStorage:storage,initAccountSettings(){}},sessionStorage:storage,
    location:{hash:'',pathname:'/studio',replace(){}},history:{replaceState(){}},URLSearchParams,Date,
    setTimeout(fn){poll=fn;return 1;},clearTimeout(){},fetch:async(url,options)=>{
      let data={}; let status=200;
      if(url==='/auth/session')data={csrf:'csrf'};
      if(url==='/v1/me')data={id:'account'};
      if(url==='/v1/rooms/status')data=state;
      if(url==='/v1/rooms/join'){
        joins++; assert.equal(JSON.parse(options.body).code,'ABC234');
        status=failJoin?429:200;
        if(!failJoin)state={status:'waiting',expires:Date.now()/1000+300};
      }
      if(url==='/v1/pairing/unlink'){
        assert.equal(options.headers['X-GameNight-CSRF'],'csrf');
        status=failLeave?500:204;
        if(!failLeave)state={status:'none'};
      }
      return {status,ok:status<400,json:async()=>data};
    }};
  await vm.runInNewContext(readFileSync(path.join(__dirname,'../web/storage.js'),'utf8'),context);
  await new Promise(setImmediate);
  assert.equal(node('room-leave').textContent,'Leave room ABC234');
  assert.equal(node('qr-open').hidden,true); assert.equal(node('room-form').hidden,true);
  failLeave=true;await node('room-leave').listeners.click();
  assert.equal(node('room-leave').hidden,false);
  failLeave=false;await node('room-leave').listeners.click();
  assert.equal(node('room-leave').hidden,true); assert.equal(node('room-form').hidden,false);
  state={status:'connected',room_code:'XYZ678'}; await poll();
  assert.equal(node('room-leave').textContent,'Leave room XYZ678');
  state={status:'none'};await poll();
  assert.equal(node('qr-open').hidden,false);
  const input=node('room-code');
  input.value='abc23';await input.listeners.input();assert.equal(joins,0);
  input.value='abc234';const joining=input.listeners.input();
  await node('room-form').listeners.submit({preventDefault(){}});
  await joining;assert.equal(joins,1);assert.equal(input.value,'ABC234');
  assert.equal(input.readOnly,false);assert.equal(node('room-cancel').hidden,false);
  input.value='';await input.listeners.input();assert.equal(joins,1);
  failJoin=true;input.value='ab-c234';await input.listeners.input();
  assert.equal(joins,2);assert.match(node('room-status').textContent,/Too many/);
  assert.equal(input.readOnly,false);
  console.log('Room controls: initial connection, leave failure/success, reconnect and expired room passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
