(() => {
  if (window.gamenightDocsReady) return;
  window.gamenightDocsReady = true;
  document.documentElement.classList.add('docs-enhanced');
  document.addEventListener('click', async event => {
    const button = event.target.closest?.('.docs-menu-toggle, .docs-copy');
    if (!button) return;
    const page = button.closest('.docs-page');
    if (button.classList.contains('docs-menu-toggle')) {
      const open = button.getAttribute('aria-expanded') !== 'true';
      button.setAttribute('aria-expanded', String(open));
      page.querySelector('.docs-sidebar').dataset.open = String(open);
    } else {
      const code = button.closest('.docs-code').querySelector('code');
      const status = page.querySelector('.docs-copy-status');
      try {
        await navigator.clipboard.writeText(code.textContent);
        status.textContent = 'Code copied';
      } catch {
        const range = document.createRange(); range.selectNodeContents(code);
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        status.textContent = 'Code selected. Copy it with your browser.';
      }
      setTimeout(() => { status.textContent = ''; }, 3500);
    }
  });
  function anchor() {
    const view = document.querySelector('[data-app-view]:not([hidden]) .docs-page') || document.querySelector('body > .docs-page');
    if (!view || !location.hash) return;
    try {
      const target = view.querySelector('#' + CSS.escape(decodeURIComponent(location.hash.slice(1))));
      target?.scrollIntoView({block:'start'});
    } catch { /* Ignore malformed fragments. */ }
  }
  window.addEventListener('hashchange', anchor);
  window.addEventListener('gamenight-page-change', anchor);
  requestAnimationFrame(anchor);
})();
