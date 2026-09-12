"use strict";
const shell = document.getElementById('site-shell');
window.updatePlayerNavigation = name => {
  const link=shell?.querySelector('.site-links a[href="/studio"]');
  if(link)link.textContent=name?.trim() || 'Your player';
  if(name?.trim())sessionStorage.setItem('gamenight_nav_name',name.trim());
};
if (shell) {
  shell.innerHTML = `<nav class="site-nav" aria-label="Main navigation"><a class="site-logo" href="/"><img src="/web/icon.svg" alt="" width="32" height="32">GameNight</a><div class="site-links"><a href="/">Home</a><a href="/catalog">Games</a><a href="/studio">Your player</a><a href="/studio#session">Session</a></div></nav>`;
  const markCurrent=()=>{for(const link of shell.querySelectorAll('.site-links a')){const url=new URL(link.href,location.href);if(url.pathname===location.pathname && url.hash===location.hash)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current');}};
  markCurrent();window.addEventListener('hashchange',markCurrent);
  const nav=shell.querySelector('.site-nav');
  const join=document.getElementById('qr-open');
  const actions=document.createElement('div');actions.className='site-room-actions';
  if(join){
    join.textContent='Join';join.hidden=true;join.className='btn-primary';actions.append(join);
    const leave=document.getElementById('room-leave');if(leave)actions.append(leave);
  }else{
    const joinLink=document.createElement('a');joinLink.href='/studio#join';joinLink.hidden=true;joinLink.textContent='Join';joinLink.className='btn-primary';actions.append(joinLink);
    const endpoint=document.body.dataset.local==='true'?'/api/dev-catalog/room?profile='+encodeURIComponent(localStorage.getItem('gamenight_profile_id')||''):'/v1/rooms/status';
    fetch(endpoint,{cache:'no-store'}).then(r=>r.ok?r.json():null).then(room=>{joinLink.hidden=room?.status==='connected';}).catch(()=>{});
  }
  nav.append(actions);
  window.updatePlayerNavigation(sessionStorage.getItem('gamenight_nav_name') || localStorage.getItem('gamenight_player_name'));
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
