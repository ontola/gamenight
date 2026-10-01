// Phone UI regression test. Room responses are isolated from the real lobby.
const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  const page=await browser.newPage({viewport:{width:390,height:844}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  let state={linked:false,waiting:false,remembered:false,players:0},join,fail=false;
  await page.route('**/api/profiles/*/session',route=>route.fulfill({json:state}));
  await page.route('**/api/local-room/join',route=>{join=route.request().postDataJSON();state={...state,waiting:true,remembered:!!join.remember};return route.fulfill({status:204});});
  await page.route('**/api/profiles/*/remember',route=>{
   if(fail)return route.fulfill({status:500});
   state={...state,remembered:route.request().postDataJSON().remember};return route.fulfill({status:204});
  });
  await page.route('**/api/profiles/*/main-player',route=>{
   if(fail)return route.fulfill({status:500});
   const enabled=route.request().postDataJSON().enabled;
   state={...state,main_player:enabled,remembered:enabled};return route.fulfill({status:204});
  });
  await page.goto((process.env.GAMENIGHT_TEST_URL||'http://127.0.0.1:7913')+'/studio');
  await page.waitForFunction(()=>localStorage.getItem('gamenight_saved_profile')!==null);
  await page.bringToFront();
  await page.evaluate(()=>document.getElementById('qr-open').click());
  await page.locator('#remember-join').check();
  const bounds=await page.locator('#remember-join').boundingBox();assert.equal(bounds.width,20);
  await page.locator('#room-code').fill('ABC234');
  await page.locator('#remember-player-card').waitFor();
  if(process.env.GAMENIGHT_TEST_SCREENSHOT)await page.screenshot({path:process.env.GAMENIGHT_TEST_SCREENSHOT});
  assert.equal(join.remember,true);
  assert.equal(await page.locator('#remember-player').isChecked(),true);
  fail=true;await page.locator('#remember-player').uncheck();
  await page.waitForFunction(()=>!document.querySelector('#remember-player').disabled);
  assert.equal(await page.locator('#remember-player').isChecked(),true,'Failed save rolls back');
  fail=false;await page.locator('#remember-player').uncheck();
  await page.waitForFunction(()=>!document.querySelector('#remember-player').disabled);
  assert.equal(state.remembered,false);
  assert.equal(state.waiting,true,'Forgetting must not cancel pickup');
  state={...state,linked:true,waiting:false};
  await page.waitForFunction(()=>window.gamenightRoomConnected===true);
  await page.locator('#remember-player').check();
  await page.waitForFunction(()=>!document.querySelector('#remember-player').disabled);
  assert.equal(state.remembered,true);assert.equal(state.linked,true);
  fail=true;await page.locator('#main-player').check();
  await page.waitForFunction(()=>!document.querySelector('#main-player').disabled);
  assert.equal(await page.locator('#main-player').isChecked(),false,'Failed main-player save rolls back');
  fail=false;await page.locator('#main-player').check();
  await page.waitForFunction(()=>!document.querySelector('#main-player').disabled);
  assert.equal(state.main_player,true);
  assert.equal(await page.locator('#remember-player').isDisabled(),true);
  await page.reload();
  await page.waitForFunction(()=>document.querySelector('#main-player')?.checked);
  if(process.env.GAMENIGHT_MAIN_SCREENSHOT)await page.screenshot({path:process.env.GAMENIGHT_MAIN_SCREENSHOT});
  if(process.env.GAMENIGHT_MAIN_DESKTOP_SCREENSHOT){await page.setViewportSize({width:1280,height:900});await page.screenshot({path:process.env.GAMENIGHT_MAIN_DESKTOP_SCREENSHOT});}
  await page.locator('#main-player').uncheck();
  await page.waitForFunction(()=>!document.querySelector('#main-player').disabled);
  assert.equal(state.main_player,false);assert.equal(state.remembered,false);assert.equal(state.linked,true);
  state={...state,linked:false,waiting:false};
  await page.locator('#remember-player-card').waitFor({state:'hidden'});
  assert.deepEqual(errors,[]);
  console.log('Player memory: join, main-player switch, reload, clear without unlink, failed-save rollback and mobile controls passed.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
