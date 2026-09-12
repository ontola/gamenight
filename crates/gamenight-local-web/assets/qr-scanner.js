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
    const compactRoom=url.pathname==='/' && /^[A-Z2-9]{6}$/.test(url.searchParams.get('r')||'');
    if (!compactRoom && !/^\/(session(?:\/[^/]+)?|studio|mobile)\/?$/.test(url.pathname)) return false;
    stop();
    link.href = url.href; link.hidden = false;
    link.textContent = 'Open GameNight · ' + url.host;
    status.textContent = 'GameNight QR found. Open it to join.';
    return true;
  }
  function decode(source, width, height) {
    const scale = Math.min(1, 800 / Math.max(width, height));
    canvas.width = Math.max(1, Math.round(width * scale));
    canvas.height = Math.max(1, Math.round(height * scale));
    ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
    const pixels = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const code = window.jsQR(pixels.data, pixels.width, pixels.height);
    if (!code) return false;
    if (accept(code.data)) return true;
    status.textContent = 'This is not a GameNight sign-in QR. Try the code in the lobby.';
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
      const camera = await navigator.mediaDevices.getUserMedia({audio:false,video:{facingMode:{ideal:'environment'},width:{ideal:1280}}});
      if (current !== generation || !dialog.open) { camera.getTracks().forEach(track => track.stop()); return; }
      stream = camera; video.srcObject = stream; video.hidden = false;
      await video.play();
      function tick() {
        if (current !== generation || !dialog.open) return;
        try { if (video.readyState >= 2 && decode(video, video.videoWidth, video.videoHeight)) return; }
        catch (_) { status.textContent = 'Could not read this frame. Hold the QR steady.'; }
        timer = setTimeout(tick, 180);
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
  dialog.addEventListener('close', stop);
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
      if (!decode(image, image.naturalWidth, image.naturalHeight)) status.textContent = 'No GameNight QR found. Try a closer, sharper photo.';
    } catch (_) { status.textContent = 'Could not read this photo. Try another image.'; }
    finally { URL.revokeObjectURL(url); event.target.value = ''; }
  };
})();
