// Run against a local development host. Uses an isolated browser/profile;
// it neither controls the real lobby nor overwrites a player's saved artwork.
const assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
  try{
    for(const entry of ['/','/studio','/catalog']){
      const page=await browser.newPage({viewport:{width:390,height:844}});
      const errors=[];let documents=0;
      page.on('pageerror',error=>errors.push(error.message));
      page.on('request',request=>{if(request.isNavigationRequest() && request.frame()===page.mainFrame())documents++;});
      await page.goto((process.env.GAMENIGHT_TEST_URL || 'http://127.0.0.1:7913')+entry);
      await page.locator('.site-nav').waitFor();
      await page.evaluate(()=>window.retainedNav=document.querySelector('.site-nav'));
      const bounds=await page.locator('.site-nav').boundingBox();
      await page.locator('.site-links a[href="/studio"]').click();
      await page.locator('#pixel-grid').waitFor();
      await page.waitForFunction(()=>document.querySelector('#player-name').value.length>0);
      const name=await page.locator('#player-name').inputValue();
      await page.evaluate(()=>window.retainedCanvas=document.querySelector('#pixel-grid'));
      await page.locator('.site-links a[href="/catalog"]').click();
      await page.locator('#query').fill('Neon');
      await page.locator('.site-links a[href="/"]').click();
      await page.waitForURL(url=>url.pathname==='/');
      assert.deepEqual(await page.locator('.site-nav').boundingBox(),bounds);
      await page.locator('.site-links a[href="/catalog"]').click();
      await page.locator('#query').waitFor();
      assert.equal(await page.locator('#query').inputValue(),'Neon');
      await page.locator('.site-links a[href="/studio"]').click();
      await page.locator('#pixel-grid').waitFor();
      assert.equal(await page.locator('#player-name').inputValue(),name);
      assert.equal(await page.evaluate(()=>window.retainedCanvas===document.querySelector('#pixel-grid')),true);
      assert.equal(await page.evaluate(()=>window.retainedNav===document.querySelector('.site-nav')),true);
      assert.equal(documents,1,'Tab switching must not navigate the document');
      let linked=true;
      await page.route('**/api/profiles/*/session',request=>request.fulfill({json:{linked,players:1,player_name:name,seat:0,current:null,next:null}}));
      await page.evaluate(()=>window.updateRoomNavigation(true));
      await page.getByRole('link',{name:'Playlist',exact:true}).click();
      await page.waitForURL(url=>url.hash==='#session');
      linked=false;await page.evaluate(()=>window.updateRoomNavigation(false));
      await page.waitForURL(url=>url.hash==='');
      assert.equal(await page.locator('.site-links a[href="/studio#session"]').isVisible(),false);
      assert.equal(await page.locator('#playlist-list').textContent(),'');
      assert.deepEqual(errors,[]);
      await page.close();
    }
    console.log('SPA: all three entry points, retained navbar/canvas/profile/filters, mobile geometry, no document reload, and unlink state passed.');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
