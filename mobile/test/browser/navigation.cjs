// Uses the compiled Flutter web app and synthetic room/catalog responses.
// Run after flutter build web --release --base-href /app/.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const build=process.env.GAMENIGHT_WEB_BUILD || path.resolve(__dirname,'../../build/web');
const output=process.env.GAMENIGHT_TEST_SCREENSHOTS;
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const errors=[];let joins=0,authMutations=0;
  if(process.env.GAMENIGHT_DEBUG_SEMANTICS) page.on('console',message=>console.log(message.type(),message.text()));
  const token='synthetic-navigation-guest';
  const room={status:'connected',guest:true,room_code:'ABC234',players:2,fresh:true,seat:{index:0,player:'fixture-player',revision:1},discovery:{current:'moon-cards',games:[],playlist:{entries:[]}}};
  page.on('pageerror',e=>{errors.push(e.message);if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log(e.message);});
  await page.route('https://gamenight.ontola.io/app/**',async route=>{
   let rel=new URL(route.request().url()).pathname.slice(5);if(!rel||rel.endsWith('/'))rel+='index.html';
   const file=path.join(build,rel),types={'.html':'text/html','.js':'text/javascript','.json':'application/json','.wasm':'application/wasm','.png':'image/png','.woff2':'font/woff2'};
   if(!file.startsWith(path.resolve(build)+path.sep)||!fs.existsSync(file))return route.fulfill({status:404});
   return route.fulfill({contentType:types[path.extname(file)]||'application/octet-stream',body:fs.readFileSync(file)});
  });
  await page.route('**/auth/**',route=>{if(route.request().method()!=='GET')authMutations++;return route.fulfill({status:401,json:{}});});
  await page.route('**/v1/**',route=>{
   const p=new URL(route.request().url()).pathname;let data={};
   if(p==='/v1/catalog') data=[{id:'moon-cards',title:'Moon Cards',tagline:'A synthetic navigation fixture',developer:'Test studio',players:{min:2,max:4},price:'free',color:'#336655'}, ...['Rocket Rally','Forest Friends','Pixel Party','Space Garden','Castle Clash','River Riders','Neon Nights','Tiny Towers','Ocean Quest','Cloud Club','Desert Dash'].map((title,i)=>({id:'fixture-'+i,title,tagline:'Play together',developer:'Test studio',players:{min:2,max:4},price:'free',color:['#51428a','#245b50','#734555','#325878'][i%4]}))];
   else if(p==='/v1/rooms/guest'){joins++;data={token,status:room,profile:{display_name:'Test guest'}};}
   else if(p==='/v1/rooms/status')data=room;
   else if(p==='/v1/rooms/companion')data={game:'moon-cards',title:'Moon Cards',url:'/v1/companion/fixture-navigation/index.html'};
   else if(p.startsWith('/v1/companion/'))return route.fulfill({contentType:'text/html; charset=utf-8',body:'<!doctype html><body style="background:#163c32;color:#f5efdf;font-family:system-ui;padding:24px"><h1>Your private hand</h1><p>Browser navigation fixture</p></body>'});
   return route.fulfill({json:data});
  });
  await page.goto('https://gamenight.ontola.io/app/?room=ABC234',{waitUntil:'networkidle',timeout:60000});
  await page.frameLocator('iframe').getByText('Your private hand').waitFor({timeout:30000});
  await page.evaluate(()=>{window.originalPhone=document.querySelector('iframe');document.querySelector('flt-semantics-placeholder')?.click();});
  await page.waitForTimeout(300);
  if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log(await page.locator('body').ariaSnapshot());
  assert(!page.url().includes('room=ABC234'),'launch invitation removed from history');
  const rootURL=page.url();
  const tab=name=>page.getByRole('tab',{name:new RegExp(name)});
  await tab('Games').click();if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log('Games click',page.url());
  await page.waitForURL(/#\/games$/);
  if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log(await page.locator('body').ariaSnapshot());
  const gamesURL=page.url(),length=await page.evaluate(()=>history.length);
  await tab('Games').click();if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log('Games click',page.url());await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>history.length),length);
  await page.getByText(/A synthetic navigation fixture/).click();
  await page.waitForURL(/screen=/);
  const detailURL=page.url();
  await page.goBack();await page.waitForURL(gamesURL);
  await page.getByText(/A synthetic navigation fixture/).waitFor();
  await page.goBack();await page.waitForURL(rootURL);
  await page.frameLocator('iframe').getByText('Your private hand').waitFor();
  await page.goForward();await page.waitForURL(gamesURL);
  await page.goForward();await page.waitForURL(detailURL);
  await page.getByRole('button',{name:'Share game'}).waitFor();
  await page.getByRole('button',{name:'Back',exact:true}).click();
  await page.waitForURL(gamesURL);
  await page.goBack();await page.waitForURL(rootURL);
  await page.getByRole('button',{name:'Full screen',exact:true}).click();
  await page.waitForURL(/fullscreen=1/);
  await page.goBack();await page.waitForURL(rootURL);
  await page.getByRole('button',{name:'Full screen',exact:true}).waitFor();
  await page.goForward();await page.waitForURL(/fullscreen=1/);
  await page.getByRole('button',{name:'Exit full screen',exact:true}).waitFor();
  assert(await page.evaluate(()=>document.querySelector('iframe')===window.originalPhone),'phone iframe must stay mounted');
  assert.equal(joins,1);assert.equal(authMutations,0);assert.deepEqual(errors,[]);
  const state=await page.evaluate(()=>JSON.stringify(history.state));
  assert(!state.includes(token));assert(!state.includes('fixture-navigation'));assert(!state.includes('ABC234'));
  if(output){fs.mkdirSync(output,{recursive:true});await page.screenshot({path:path.join(output,'browser-forward-fullscreen-phone.png')});}
  await page.goBack();await page.waitForURL(rootURL);
  await tab('Games').click();if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log('Games click',page.url());await page.waitForURL(gamesURL);
  if(output){await page.mouse.move(0,0);await page.waitForTimeout(400);await page.screenshot({path:path.join(output,'games-phone.png')});}
  for(const width of [1280,1920,390]) {
   await page.setViewportSize({width,height:900});await page.waitForTimeout(500);
   assert(await page.evaluate(()=>document.querySelector('iframe')===window.originalPhone),'resize keeps the private frame');
   if(width>=900){
    if(output)await page.screenshot({path:path.join(output,'games-desktop-'+width+'.png')});
    await page.getByText('A synthetic navigation fixture').click();
    await page.getByRole('button',{name:'Next game (Right arrow)'}).click();
    await page.getByText('Rocket Rally',{exact:true}).first().waitFor();
    await page.keyboard.press('ArrowLeft');await page.waitForTimeout(400);
    await page.getByRole('button',{name:'Back',exact:true}).click();
    await page.waitForURL(gamesURL);
   }
  }
  await page.getByRole('button',{name:'Menu',exact:true}).click();
  await page.getByText('Developer portal',{exact:true}).waitFor();
  await page.getByText('Assistant',{exact:true}).click();
  await page.waitForURL(/#\/assistant/);
  await page.getByText('Your room, with a little help').waitFor();
  await page.goBack(); await page.waitForURL(gamesURL);
  assert(await page.evaluate(()=>document.querySelector('iframe')===window.originalPhone),'Assistant Back preserves the private game');
  assert.equal(joins,1);assert.deepEqual(errors,[]);
  // Existing website guest migrates into Flutter without another pickup.
  await page.evaluate(()=>{
   localStorage.clear();sessionStorage.clear();
   sessionStorage.setItem('gamenight_guest_v1',JSON.stringify({token:'synthetic-navigation-guest',room:'ABC234',profile:{display_name:'Returning guest'}}));
  });
  await page.goto('https://gamenight.ontola.io/app/?room=ABC234',{waitUntil:'networkidle'});
  await page.frameLocator('iframe').getByText('Your private hand').waitFor();
  assert.equal(joins,1,'Migrated website guest must not join again');
  assert.equal(await page.evaluate(()=>sessionStorage.getItem('gamenight_guest_v1')),null);
  assert(!page.url().includes(token));assert.deepEqual(errors,[]);
  // Choosing a game on the website survives joining, but does not queue it.
  await page.goto('https://gamenight.ontola.io/app/?room=ABC234&game=fixture-0',{waitUntil:'networkidle'});
  await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.click());
  await page.getByRole('button',{name:'Share game'}).waitFor({timeout:30000});
  await page.getByText('Rocket Rally',{exact:true}).first().waitFor();
  assert.equal(joins,1);assert.deepEqual(errors,[]);
  console.log('PASS desktop/phone resizing, keyboard browsing, menu, website guest migration; browser Back/Forward across Room, Games, detail and fullscreen; app Back; no duplicate tab history; original iframe/session retained; no invitation replay or secrets in history.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
