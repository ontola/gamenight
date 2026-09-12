"use strict";
const shell = document.getElementById('site-shell');
if (shell) {
  shell.innerHTML = `<nav class="site-nav" aria-label="Main navigation"><a class="site-logo" href="/"><img src="/web/icon.svg" alt="" width="32" height="32">GameNight</a><div class="site-links"><a href="/">Home</a><a href="https://gamenight.ontola.io/catalog">Games</a><a href="/studio">Your player</a><a href="/studio#session">Session</a></div></nav>`;
  const markCurrent=()=>{for(const link of shell.querySelectorAll('.site-links a')){const url=new URL(link.href,location.href);if(url.pathname===location.pathname && url.hash===location.hash)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current');}};
  markCurrent();window.addEventListener('hashchange',markCurrent);
}

if(shell && document.body.classList.contains('studio-page') && document.body.dataset.cloud !== 'true') {
  for(const link of shell.querySelectorAll('a')) if(link.getAttribute('href') !== '/studio' && link.getAttribute('href').startsWith('/')) link.href='https://gamenight.ontola.io'+link.getAttribute('href');
}

// One transient notification surface, shared by room and account actions.
window.showToast = (() => {
  let toast, message, timeout;
  return text => {
    if (!toast) {
      toast = document.createElement("div"); toast.className = "app-toast";
      message = document.createElement("span"); message.setAttribute("role", "status"); message.setAttribute("aria-live", "polite");
      const close = document.createElement("button"); close.type = "button"; close.className = "icon-btn";
      close.textContent = "×"; close.setAttribute("aria-label", "Dismiss notification");
      close.onclick = () => { clearTimeout(timeout); toast.hidden = true; };
      toast.append(message, close);
      toast.addEventListener("pointerenter", () => clearTimeout(timeout));
      toast.addEventListener("pointerleave", () => { timeout = setTimeout(() => { toast.hidden = true; }, 6000); });
    }
    clearTimeout(timeout);
    (document.querySelector("dialog[open]") || document.body).append(toast);
    message.textContent = text; toast.hidden = false;
    timeout = setTimeout(() => { toast.hidden = true; }, 8000);
  };
})();
