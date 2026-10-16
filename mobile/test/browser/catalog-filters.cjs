// Compiled-app checks using synthetic account/history data; no live writes.
const {chromium,devices}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const build=process.env.GAMENIGHT_WEB_BUILD || path.resolve(__dirname,'../../build/web');
const out=process.env.GAMENIGHT_TEST_SCREENSHOTS;
const ids=['blast-party','bubble-buddies','ricochet-club'];
const games=ids.map(id=>{
 const g=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../../catalog/games',id+'.json')));
 const png=path.resolve(__dirname,'../../../catalog/art',id,'screenshot.png');
 g.media={items:[]};g.screenshot=null;g.cover='data:image/png;base64,'+fs.readFileSync(png).toString('base64');
 return g;
});
games[0].tags=['party','action'];games[1].tags=['co-op','party'];games[2].tags=['action'];
(async()=>{
 const browser=await chromium.launch({headless:true});
 try {
  const context=await browser.newContext({...devices['Pixel 7'],deviceScaleFactor:1});
  let signedIn=true;const errors=[];
  await context.route('https://gamenight.ontola.io/app/**',route=>{
   let rel=new URL(route.request().url()).pathname.slice(5);if(!rel||rel.endsWith('/'))rel+='index.html';
   const file=path.join(build,rel),types={'.html':'text/html','.js':'text/javascript','.json':'application/json','.wasm':'application/wasm','.png':'image/png','.woff2':'font/woff2'};
   if(!file.startsWith(path.resolve(build)+path.sep)||!fs.existsSync(file))return route.fulfill({status:404});
   return route.fulfill({contentType:types[path.extname(file)]||'application/octet-stream',body:fs.readFileSync(file)});
  });
  await context.route('**/auth/**',route=>route.fulfill(signedIn ? {json:{csrf:'synthetic-csrf'}} : {status:401,json:{}}));
  await context.route('**/v1/**',route=>{
   const p=new URL(route.request().url()).pathname;
   const data={
    '/v1/catalog':games,
    '/v1/me':{id:'test-account',profile:{display_name:'Test player'}},
    '/v1/me/studio':{revision:0,profile:{display_name:'Test player'}},
    '/v1/me/game-ratings':{'blast-party':1,'bubble-buddies':1,'ricochet-club':-1},
    '/v1/me/play-profile':{window_days:90,games:[{game:'blast-party',active_ms:2000,rounds_reported:0}]},
    '/v1/rooms/status':{status:'none'},
   }[p] ?? {};
   return route.fulfill({json:data});
  });
  const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
  async function semantics(){await page.waitForFunction(()=>document.querySelector('flt-semantics-placeholder'));await page.evaluate(()=>{const e=document.querySelector('flt-semantics-placeholder'),r=e.getBoundingClientRect();e.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2}));});}
  async function shot(name){if(out){fs.mkdirSync(out,{recursive:true});await page.waitForTimeout(300);await page.screenshot({path:path.join(out,name+'.png')});}}
  await page.goto('https://gamenight.ontola.io/app/#/games',{waitUntil:'networkidle'});await semantics(); await page.waitForTimeout(500); if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log(await page.locator('body').ariaSnapshot());
  await page.getByRole('button',{name:'Filter',exact:true}).waitFor();
  await shot('catalog-phone');
  await page.getByRole('button',{name:'Filter',exact:true}).click();
  // Flutter chips expose checkbox semantics.
  if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log(await page.locator('body').ariaSnapshot());
  await page.getByRole('checkbox',{name:'Liked',exact:true}).click();await page.getByRole('checkbox',{name:'Not played',exact:true}).click();
  await page.getByRole('button',{name:'Show 1 game',exact:true}).waitFor();
  await shot('filters-phone');
  await page.getByRole('button',{name:'Show 1 game',exact:true}).click(); await page.waitForTimeout(500);if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log('AFTER FILTER',await page.locator('body').ariaSnapshot());await shot('filtered-phone');
  await page.getByRole('group',{name:new RegExp('^'+games[1].title+' ')}).waitFor();
  assert.equal(await page.getByRole('group',{name:new RegExp('^'+games[0].title+' ')}).count(),0);
  await shot('filtered-phone');
  await page.getByRole('group',{name:new RegExp('^'+games[1].title+' ')}).click();
  assert.equal(await page.getByText('Give feedback',{exact:true}).count(),0);
  await page.setViewportSize({width:1280,height:900});await page.getByText('Feedback',{exact:true}).click();await page.waitForTimeout(400);if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log('FEEDBACK',await page.locator('body').ariaSnapshot());
  await page.getByText('Sent to the developer of Bubble Buddies.',{exact:true}).waitFor();
  await page.getByRole('button',{name:/^Back/}).click();
  await page.mouse.move(950,700);await page.mouse.wheel(0,600);await page.waitForTimeout(400);if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log('TAGS',await page.locator('body').ariaSnapshot());await page.getByRole('checkbox',{name:'party',exact:true}).click();await page.setViewportSize({width:412,height:915});
  await page.getByRole('button',{name:'Filter',exact:true}).waitFor();
  await page.getByRole('group',{name:new RegExp('^'+games[0].title+' ')}).waitFor();
  await page.getByRole('group',{name:new RegExp('^'+games[1].title+' ')}).waitFor();
  await page.getByRole('tab',{name:/You/}).click();
  await page.getByRole('button',{name:'Download APK',exact:true}).waitFor();
  await shot('android-install-phone');
  // Test the actual target without downloading a real installer.
  await context.route('https://github.com/ontola/gamenight/releases/download/app-latest/gamenight.apk',route=>route.fulfill({contentType:'application/vnd.android.package-archive',headers:{'Content-Disposition':'attachment; filename="gamenight.apk"'},body:'synthetic-download'}));
  const request=context.waitForEvent('request',{predicate:r=>r.url().endsWith('/app-latest/gamenight.apk')});
  await page.getByRole('button',{name:'Download APK',exact:true}).click();await request;
  signedIn=false;
  await page.goto('https://gamenight.ontola.io/app/#/room',{waitUntil:'networkidle'});await page.reload({waitUntil:'networkidle'});await semantics(); await page.waitForTimeout(500); if(process.env.GAMENIGHT_DEBUG_SEMANTICS)console.log(await page.locator('body').ariaSnapshot());
  const input=page.getByRole('textbox').first();await input.click();
  await shot('room-code-phone');
  await input.fill('ab2');await shot('room-code-typed-phone');
  assert.equal(await input.inputValue(),'AB2');
  await page.getByRole('tab',{name:/Games/}).click();
  await page.setViewportSize({width:1280,height:900});await page.waitForTimeout(300);
  await shot('catalog-desktop');
  await page.getByRole('button',{name:'Filter',exact:true}).click();
  await page.getByText('Sign in to filter by your likes and play history.').waitFor();
  assert.deepEqual(errors,[]);console.log('PASS filters, tag navigation, contextual feedback, Android APK target, six-slot room code, desktop layout');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
