const { chromium } = require('playwright');
const { spawn } = require('child_process');
(async () => {
  const mode = process.argv[2]; // "stills t1,t2,..." or "video out.mp4"
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1920, height: 1080 } });
  p.on('console', m => console.log('page:', m.text())); p.on('pageerror', e => console.log('ERR', e.message));
  await p.goto('file://' + __dirname + '/compose.html');
  await p.evaluate(() => window.ready);
  if (mode === 'stills') {
    for (const t of process.argv[3].split(',').map(Number)) { await p.evaluate(t => render(t), t); await p.screenshot({ path: `shots/t${t}.jpg`, quality: 85, type: 'jpeg' }); }
  } else {
    const dur = await p.evaluate(() => DUR); const n = Math.round(dur * 30);
    const ff = spawn('ffmpeg', ['-v', 'error', '-y', '-f', 'image2pipe', '-framerate', '30', '-c:v', 'mjpeg', '-i', '-', '-c:v', 'libx264', '-preset', 'slow', '-crf', '14', '-pix_fmt', 'yuv420p', process.argv[3]], { stdio: ['pipe', 'inherit', 'inherit'] });
    for (let i = 0; i < n; i++) { await p.evaluate(t => render(t), i / 30); const buf = await p.screenshot({ type: 'jpeg', quality: 95 }); if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r)); if (i % 150 === 0) console.log('frame', i, '/', n); }
    ff.stdin.end(); await new Promise(r => ff.on('close', r));
  }
  await b.close();
})();
