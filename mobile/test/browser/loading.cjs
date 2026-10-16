// Exercises the pre-Flutter page: it must be useful before any Dart is loaded.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const build=process.env.GAMENIGHT_WEB_BUILD||path.resolve(__dirname,'../../build/web');
const output=process.env.GAMENIGHT_TEST_SCREENSHOTS;
(async()=>{
 const browser=await chromium.launch({headless:true});
 try {
  const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true,deviceScaleFactor:3,reducedMotion:'reduce'});
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
  // Real mobile emulation: without an early viewport the browser starts at
  // ~980 CSS px, then jumps when Flutter sets its device-width viewport.
  assert.equal(await page.evaluate(()=>innerWidth),390,'loader must use the phone viewport before Flutter boots');
  const before=await page.locator('#app-loading').boundingBox();
  await page.evaluate(()=>{
   const meta=document.querySelector('meta[name=viewport]');
   meta.content='width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
  });
  assert.deepEqual(await page.locator('#app-loading').boundingBox(),before,'Flutter viewport setup must not resize the loader');
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
  console.log('PASS stable mobile viewport before/after Flutter setup, branded pre-Flutter loader, reduced motion, first-frame removal and recoverable bootstrap failure.');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
