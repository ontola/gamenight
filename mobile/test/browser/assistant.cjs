// Native Flutter Assistant against synthetic room/API replies, never a paid model.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const build=process.env.GAMENIGHT_WEB_BUILD || path.resolve(__dirname,'../../build/web');
const output=process.env.GAMENIGHT_TEST_SCREENSHOTS;
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const errors=[],posts=[];let quoted=0,requests=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://gamenight.ontola.io/app/**',async route=>{
   let rel=new URL(route.request().url()).pathname.slice(5);if(!rel||rel.endsWith('/'))rel+='index.html';
   const file=path.join(build,rel),types={'.html':'text/html','.js':'text/javascript','.json':'application/json','.wasm':'application/wasm','.png':'image/png','.woff2':'font/woff2'};
   if(!file.startsWith(path.resolve(build)+path.sep)||!fs.existsSync(file))return route.fulfill({status:404});
   return route.fulfill({contentType:types[path.extname(file)]||'application/octet-stream',body:fs.readFileSync(file)});
  });
  await page.route('**/auth/**',r=>r.fulfill({json:{csrf:'synthetic-csrf'}}));
  const controls={game:'frog-fighter',instance:'test-frog',revision:1,can_undo:true,settings:{gravity:{label:'Gravity',kind:'number',value:80,min:20,max:200}}};
  await page.route('**/v1/**',route=>{
   const req=route.request(),p=new URL(req.url()).pathname;let data={};
   if(p==='/v1/me')data={id:'synthetic',assistant:true,profile:{display_name:'Test player'}};
   else if(p==='/v1/me/studio')data={revision:1,profile:{display_name:'Test player'},workspace:null};
   else if(p==='/v1/catalog')data=[];
   else if(p==='/v1/rooms/status')data={status:'connected',room_code:'ABC234',fresh:true,players:2,main_player:true,discovery:{current:'frog-fighter'}};
   else if(p==='/v1/rooms/agent/presets')data={presets:[]};
   else if(p==='/v1/rooms/agent/quote'){quoted++;data={maximum_credits:3};}
   else if(p==='/v1/rooms/agent'){
    if(req.method()==='POST'){
     const body=req.postDataJSON();assert.equal(req.headers()['x-gamenight-csrf'],'synthetic-csrf');posts.push(body);
     requests=[{id:body.request_id,prompt:body.text,speaker_name:'Test player',state:'complete',result:'Gravity is now 80%. You can jump a little higher.'}];
    }
    data={provider_configured:true,local_model:false,can_fund:true,credits:{available:100},funding:{remaining:50},controls,requests};
   }
   return route.fulfill({json:data});
  });
  await page.goto('https://gamenight.ontola.io/app/#/assistant',{waitUntil:'networkidle',timeout:90000});
  await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.click());
  await page.getByText('What shall we change?',{exact:true}).waitFor({timeout:30000});
  await page.getByRole('textbox').fill('Make us jump a little higher');
  await page.getByRole('button',{name:'Review request',exact:true}).click();
  await page.getByText('Up to 3 credits. Unused credits are returned.',{exact:true}).waitFor();
  assert.equal(posts.length,0,'quote must not send a paid request');assert.equal(quoted,1);
  if(output){fs.mkdirSync(output,{recursive:true});await page.screenshot({path:path.join(output,'assistant-phone-review.png')});}
  await page.getByRole('button',{name:'Send · up to 3 credits',exact:true}).click();
  await page.getByText('Gravity is now 80%. You can jump a little higher.').first().waitFor();
  assert.equal(posts.length,1);assert.equal(posts[0].max_credits,3);
  if(output)await page.screenshot({path:path.join(output,'assistant-phone.png')});
  await page.setViewportSize({width:1440,height:1000});await page.waitForTimeout(500);
  if(output)await page.screenshot({path:path.join(output,'assistant-desktop.png')});
  await page.reload({waitUntil:'networkidle'});
  await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.click());
  await page.getByText('Gravity is now 80%. You can jump a little higher.').first().waitFor();
  assert.equal(posts.length,1,'reload must not replay a request');assert.deepEqual(errors,[]);
  console.log('PASS Assistant deep link, phone/desktop UI, explicit paid review, CSRF, host result and reload without replay.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
