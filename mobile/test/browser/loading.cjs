// Exercises the pre-Flutter page: it must be useful before any Dart is loaded.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const build=process.env.GAMENIGHT_WEB_BUILD||path.resolve(__dirname,'../../build/web');
const output=process.env.GAMENIGHT_TEST_SCREENSHOTS;
(async()=>{
 const browser=await chromium.launch({headless:true});
 try {
  const page=await browser.newPage({viewport:{width:390,height:844},reducedMotion:'reduce'});
  let release,failed=false;
  await page.route('https://gamenight.ontola.io/app/**',async route=>{
   const rel=new URL(route.request().url()).pathname.slice(5)||'index.html';
   if(rel==='flutter_bootstrap.js') {
    if(failed)return route.abort('failed');
    await new Promise(resolve=>release=resolve);
    return route.fulfill({contentType:'text/javascript',body:''});
   }
   const file=path.join(build,rel);
   if(!fs.existsSync(file))return route.fulfill({status:404});
   return route.fulfill({body:fs.readFileSync(file),contentType:rel.endsWith('.html')?'text/html':rel.endsWith('.svg')?'image/svg+xml':'application/octet-stream'});
  });
  await page.clock.install();
  await page.goto('https://gamenight.ontola.io/app/',{waitUntil:'domcontentloaded'});
  await page.getByText('Getting ready…').waitFor();
  assert.equal(await page.locator('.loading-brand img').evaluate(e=>getComputedStyle(e).animationName),'none');
  if(output){fs.mkdirSync(output,{recursive:true});await page.screenshot({path:path.join(output,'loading-phone.png')});}
  await page.clock.fastForward(21000);
  await page.getByText('Still loading. Check your connection or try again.').waitFor();
  await page.getByRole('button',{name:'Try again'}).waitFor();
  release();
  await page.evaluate(()=>window.dispatchEvent(new Event('flutter-first-frame')));
  assert.equal(await page.locator('#app-loading').count(),0);
  failed=true;
  await page.reload({waitUntil:'networkidle'});
  await page.getByText('GameNight could not load. Please try again.').waitFor();
  await page.getByRole('button',{name:'Try again'}).waitFor();
  console.log('PASS branded pre-Flutter loader, reduced motion, first-frame removal and recoverable bootstrap failure.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
