// Starting a game, playing it next and its settings, from the website's
// playlist: what web/storage.js sends on the LAN and to an online room.
const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const path=require('node:path');
(async()=>{
  const nodes=new Map();
  function node(id){if(!nodes.has(id))nodes.set(id,{children:[],hidden:false,listeners:{},addEventListener(n,fn){this.listeners[n]=fn;},append(){},prepend(){},setAttribute(){}});return nodes.get(id);}
  const storage={getItem:key=>key==='gamenight_profile_id'?'saved-player':null,setItem(){},removeItem(){}};
  const context={document:{body:{dataset:{cloud:'false'},append(){}},getElementById:node,querySelector:node,createElement:()=>node('new')},
    window:{showToast(){},localStorage:storage,initAccountSettings(){}},sessionStorage:storage,crypto,AbortSignal,
    location:{hash:'',pathname:'/studio',replace(){}},history:{replaceState(){}},URLSearchParams,Date,setTimeout,clearTimeout(){}};
  const controls={game:'ballkickers',instance:'s1',revision:3,can_undo:false,settings:{items:{kind:'toggle',label:'Items',value:true}}};
  const sent=[];
  context.fetch=async(url,options={})=>{
    sent.push([url,options.body&&JSON.parse(options.body)]);
    if(url==='/api/playlist/next')return {ok:true,status:200,json:async()=>({playlist:{entries:[]}})};
    if(url.startsWith('/api/settings?'))return {ok:true,status:200,json:async()=>url.endsWith('game=ballkickers')?controls:null};
    if(url==='/api/settings')return {ok:false,status:409,json:async()=>({error:'Settings changed; read the current revision and retry'})};
    return {ok:true,status:200,json:async()=>({})};
  };
  await vm.runInNewContext(readFileSync(path.join(__dirname,'../web/storage.js'),'utf8'),context);
  const lan=context.window.gamenightStorage;
  await lan.playNext('ballkickers',true);
  assert.deepEqual(sent.at(-1),['/api/playlist/next',{profile:'saved-player',game:'ballkickers',start:true}]);
  assert.equal((await lan.settings('ballkickers')).instance,'s1');
  assert.equal(sent.at(-1)[0],'/api/settings?profile=saved-player&game=ballkickers');
  assert.equal(await lan.settings('other'),null);
  await assert.rejects(()=>lan.applySettings(controls,{items:false}),/revision/);
  assert.deepEqual(sent.at(-1)[1],{profile:'saved-player',command:{action:'set',instance:'s1',expected_revision:3,values:{items:false}}});

  // Online rooms start through the website, and only show the game on screen.
  context.document.body.dataset.cloud='true';
  sent.length=0;
  context.fetch=async(url,options={})=>{
    sent.push([url,options.body&&JSON.parse(options.body),options.headers]);
    if(url==='/auth/session')return {ok:true,status:200,json:async()=>({csrf:'csrf'})};
    if(url==='/v1/me')return {ok:true,status:200,json:async()=>({id:'account'})};
    if(url==='/v1/rooms/status')return {ok:true,status:200,json:async()=>({status:'connected',room_code:'ABC234',discovery:{controls}})};
    if(url==='/v1/rooms/next')return {ok:false,status:409,json:async()=>({})};
    return {ok:true,status:200,json:async()=>({})};
  };
  await vm.runInNewContext(readFileSync(path.join(__dirname,'../web/storage.js'),'utf8'),context);
  const online=context.window.gamenightStorage;
  await assert.rejects(()=>online.playNext('ballkickers',true),/cannot play that game/);
  const start=sent.find(([url])=>url==='/v1/rooms/next');
  assert.equal(start[1].start,true);assert.equal(start[1].game,'ballkickers');assert.equal(start[2]['X-GameNight-CSRF'],'csrf');
  assert.equal((await online.settings('ballkickers')).game,'ballkickers');
  assert.equal(await online.settings('other'),null);
  console.log('Playlist actions: start, play next and settings requests passed on the LAN and online.');
})().catch(error=>{console.error(error);process.exitCode=1;});
