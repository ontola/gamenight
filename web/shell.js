"use strict";
const shell = document.getElementById('site-shell');
if (shell) {
  shell.innerHTML = `<nav class="site-nav" aria-label="Main navigation"><a class="site-logo" href="/"><img src="/web/icon.svg" alt="" width="32" height="32">GameNight</a><div class="site-links"><a href="/">Home</a><a href="/dev.html">Developers</a><a href="/studio">Your player</a></div></nav>`;
  for (const link of shell.querySelectorAll('.site-links a')) if (link.getAttribute('href') === location.pathname) link.setAttribute('aria-current', 'page');
}

if(shell && document.body.classList.contains('studio-page') && document.body.dataset.cloud !== 'true') {
  for(const link of shell.querySelectorAll('a')) if(link.getAttribute('href') !== '/studio') link.href='https://gamenight.ontola.io'+link.getAttribute('href');
}
