// Keep installer sizes current without downloading the installers themselves.
let checked = false;
async function updateDownloadSizes() {
  if (checked || location.pathname !== '/host') return;
  checked = true;
  await Promise.allSettled([
    ['windows', '/download/GameNight-Setup.exe'],
    ['macos', '/download/GameNight.dmg'],
  ].map(async ([platform, url]) => {
    const response = await fetch(url, { method: 'HEAD', signal: AbortSignal.timeout(5000) });
    const bytes = Number(response.headers.get('content-length'));
    if (!response.ok || !Number.isFinite(bytes) || bytes <= 0) return;
    const label = document.querySelector(`[data-download-size="${platform}"]`);
    if (label) label.textContent = `${(bytes / 1e6).toFixed(1)} MB`;
  }));
}
window.addEventListener('gamenight-page-change', updateDownloadSizes);
void updateDownloadSizes();
