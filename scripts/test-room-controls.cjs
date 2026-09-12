const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const path=require('node:path');
(async()=>{
  const nodes=new Map();
  function node(id){if(!nodes.has(id))nodes.set(id,{children:Array.from({length:6},()=>({textContent: ""})),hidden:false,disabled:false,textContent:'',listeners:{},addEventListener(n,fn){this.listeners[n]=fn;},close(){this.open=false;},append(){},prepend(){},setAttribute(){}});return nodes.get(id);}
  let state={status:'connected',room_code:'ABC234'}, poll, failLeave=false, joins=0, failJoin=false;
  const storage={getItem(){return null;},setItem(){},removeItem(){}};
  const context={document:{body:{dataset:{cloud:'true'},append(){}},getElementById:node,querySelector:node,createElement:()=>node('new')},window:{showToast(text){node('room-status').textContent=text;},localStorage:storage,initAccountSettings(){}},sessionStorage:storage,
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
  // A saved local profile is not necessarily attached to this lobby. Never
  // read or mutate its playlist after the controller has been unlinked.
  context.document.body.dataset.cloud='false';
  storage.getItem=key=>key==='gamenight_profile_id'?'saved-player':null;
  let attached=false, playlistRequests=0, navigation;
  context.AbortSignal=AbortSignal;
  context.window.updateRoomNavigation=value=>navigation=value;
  context.fetch=async url=>({ok:true,status:200,json:async()=>{
    if(url==='/api/profiles/saved-player/session')return {linked:attached};
    if(url==='/api/playlist'){playlistRequests++;return {playlist:{entries:[]}};}
    throw Error('Unexpected request '+url);
  }});
  await vm.runInNewContext(readFileSync(path.join(__dirname,'../web/storage.js'),'utf8'),context);
  await assert.rejects(()=>context.window.gamenightStorage.playlist(),/Join a room/);
  await assert.rejects(()=>context.window.gamenightStorage.playlist({from:0,to:1}),/Join a room/);
  assert.equal(playlistRequests,0);assert.equal(navigation,false);
  attached=true;await context.window.gamenightStorage.playlist();assert.equal(playlistRequests,1);
  console.log('Room controls: initial connection, leave failure/success, reconnect and expired room passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
