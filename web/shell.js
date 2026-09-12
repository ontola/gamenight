"use strict";
const shell = document.getElementById('site-shell');
if (shell) {
  shell.innerHTML = `<nav class="site-nav" aria-label="Main navigation"><a class="site-logo" href="/"><img src="/web/icon.svg" alt="" width="32" height="32">GameNight</a><div class="site-links"><a href="/">Home</a><a href="/dev.html">Developers</a><a href="/studio">Studio</a><a href="/account">Your account</a></div></nav>`;
  for (const link of shell.querySelectorAll('.site-links a')) if (link.getAttribute('href') === location.pathname) link.setAttribute('aria-current', 'page');
}
