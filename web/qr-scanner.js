// Camera frames are decoded on this device; nothing is uploaded.
(() => {
  const dialog = document.getElementById('qr-scanner');
  const video = document.getElementById('qr-video');
  const status = document.getElementById('qr-status');
  const link = document.getElementById('qr-result');
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d', {willReadFrequently:true});
  let stream = null, timer = null, generation = 0;
  function stop() {
    generation++;
    clearTimeout(timer);
    if (stream) stream.getTracks().forEach(track => track.stop());
    stream = null; video.srcObject = null; video.hidden = true;
  }
  function accept(text) {
    let url;
    try { url = new URL(text); } catch (_) { return false; }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return false;
    // Automatic navigation is only safe for our hosted app or this local host.
    if (url.origin !== window.location.origin && url.origin !== 'https://gamenight.ontola.io') return false;
    if (!/^\/(session(?:\/[^/]+)?|studio|mobile)\/?$/.test(url.pathname)) return false;
    stop();
    link.hidden = true;
    status.textContent = 'Opening room…';
    dialog.close();
    const samePage = url.origin === window.location.origin && url.pathname === window.location.pathname && url.search === window.location.search;
    window.location.assign(url.href);
    // A fragment-only navigation otherwise leaves the existing editor running
    // without processing the newly scanned invitation.
    if (samePage) window.location.reload();
    return true;
  }
  let detector=null, cropIndex=0;
  const detectorReady=(async()=>{
    try {
      if(window.BarcodeDetector && (await window.BarcodeDetector.getSupportedFormats()).includes("qr_code"))
        detector=new window.BarcodeDetector({formats:["qr_code"]});
    } catch (_) { /* jsQR remains available on browsers without native detection. */ }
  })();
  function decodeRegion(source,x,y,width,height,maxSize) {
    const scale=Math.min(1,maxSize/Math.max(width,height));
    canvas.width=Math.max(1,Math.round(width*scale));canvas.height=Math.max(1,Math.round(height*scale));
    ctx.drawImage(source,x,y,width,height,0,0,canvas.width,canvas.height);
    const pixels=ctx.getImageData(0,0,canvas.width,canvas.height);
    const code=window.jsQR(pixels.data,pixels.width,pixels.height);
    if(!code)return false;
    if(accept(code.data))return true;
    status.textContent="This is not a GameNight sign-in QR. Try the code in the lobby.";
    return false;
  }
  async function decode(source,width,height,current,photo=false) {
    await detectorReady;
    if(current!==generation || !dialog.open || !width || !height)return false;
    if(detector) {
      try {
        const codes=await detector.detect(source);
        if(current!==generation || !dialog.open)return false;
        for(const code of codes)if(accept(code.rawValue))return true;
      } catch (_) { detector=null; }
    }
    if(decodeRegion(source,0,0,width,height,1600))return true;
    // Overlapping high-detail views preserve tiny codes anywhere in the frame.
    // Cycle one per video frame; photos get all five without requiring retakes.
    const views=[[0,0],[.4,0],[0,.4],[.4,.4],[.2,.2]];
    for(let i=0;i<(photo?views.length:1);i++) {
      const [x,y]=views[cropIndex++%views.length];
      if(decodeRegion(source,x*width,y*height,width*.6,height*.6,1600))return true;
    }
    return false;
  }
  async function startCamera() {
    stop(); link.hidden = true;
    const current = generation;
    if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
      status.textContent = 'Live camera needs a secure connection. Use “Scan a photo” instead.';
      return;
    }
    status.textContent = 'Allow camera access, then point at the lobby QR.';
    try {
      const camera = await navigator.mediaDevices.getUserMedia({audio:false,video:{facingMode:{ideal:'environment'},width:{ideal:1920},height:{ideal:1080}}});
      if (current !== generation || !dialog.open) { camera.getTracks().forEach(track => track.stop()); return; }
      stream = camera; video.srcObject = stream; video.hidden = false;
      const track=stream.getVideoTracks()[0];
      try { if(track.getCapabilities?.().focusMode?.includes("continuous"))await track.applyConstraints({advanced:[{focusMode:"continuous"}]}); } catch (_) {}
      if(current!==generation || !dialog.open)return;
      await video.play();
      async function tick() {
        if (current !== generation || !dialog.open) return;
        try { if (video.readyState >= 2 && await decode(video, video.videoWidth, video.videoHeight,current)) return; }
        catch (_) { status.textContent = 'Could not read this frame. Hold the QR steady.'; }
        if(current===generation && dialog.open)timer = setTimeout(tick, 220);
      }
      tick();
    } catch (error) {
      if (current !== generation) return;
      stop();
      status.textContent = error.name === 'NotAllowedError'
        ? 'Camera access was denied. Allow it in your browser, or scan a photo.'
        : 'Could not open the camera. Try again or scan a photo.';
    }
  }
  document.getElementById('qr-open').onclick = () => { dialog.showModal(); startCamera(); };
  document.getElementById('qr-retry').onclick = startCamera;
  document.getElementById('qr-close').onclick = () => dialog.close();
  // A backdrop tap is targeted at the dialog too. Check bounds so taps on
  // its padding/content never close it, and drags out of the dialog are safe.
  let backdropPointer = null;
  function outside(event) {
    const rect = dialog.getBoundingClientRect();
    return event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right
      || event.clientY < rect.top || event.clientY > rect.bottom);
  }
  dialog.addEventListener('pointerdown', event => {
    backdropPointer = event.isPrimary && event.button === 0 && outside(event) ? event.pointerId : null;
  });
  dialog.addEventListener('pointerup', event => {
    if (event.pointerId === backdropPointer && outside(event)) dialog.close();
    backdropPointer = null;
  });
  dialog.addEventListener('pointercancel', () => { backdropPointer = null; });
  dialog.addEventListener('close', () => { backdropPointer = null; stop(); });
  window.addEventListener('pagehide', stop);
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
  document.getElementById('qr-photo').onchange = async event => {
    const file = event.target.files?.[0]; if (!file) return;
    stop(); link.hidden = true;
    const current = generation;
    const url = URL.createObjectURL(file);
    try {
      const image = new Image(); image.src = url; await image.decode();
      if (current !== generation || !dialog.open) return;
      if (!await decode(image, image.naturalWidth, image.naturalHeight,current,true) && current===generation) status.textContent = 'No GameNight QR found. Try a closer, sharper photo.';
    } catch (_) { status.textContent = 'Could not read this photo. Try another image.'; }
    finally { URL.revokeObjectURL(url); event.target.value = ''; }
  };
})();
