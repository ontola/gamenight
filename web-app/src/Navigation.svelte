<script lang="ts">
  import { room, roomJoined, roomWaiting, route, busy, signedIn, assistantUrl } from './state';
  import { navigate } from './router';
  let leaveDialog: HTMLDialogElement;
  let menuDialog: HTMLDialogElement;
  function openLeave() {
    menuDialog.close();
    leaveError='';
    leaveDialog.showModal();
  }
  let leaving = false;
  let leaveError = '';
  async function leave() {
    leaving=true; leaveError='';
    try {
      const local=document.body.dataset.local==='true';
      let path=$roomWaiting?'/v1/rooms/cancel':'/v1/pairing/unlink';
      const headers: Record<string,string>={'Content-Type':'application/json'};
      if(local){
        const player=localStorage.getItem('gamenight_bound_player');
        if(!player && !$roomWaiting)throw Error('Open You to refresh your controller connection, then try again.');
        path=$roomWaiting?'/api/local-room/cancel/'+encodeURIComponent(localStorage.getItem('gamenight_profile_id') || ''):'/api/player-links/'+encodeURIComponent(player!)+'/unlink';
      }else{
        const session=await fetch('/auth/session',{cache:'no-store'});
        if(!session.ok)throw Error('Please sign in again before leaving the room.');
        headers['X-GameNight-CSRF']=(await session.json()).csrf;
      }
      const response=await fetch(path,{method:'POST',headers,body:'{}',signal:AbortSignal.timeout(10000)});
      if(!response.ok)throw Error('Could not leave the room. Please try again.');
      localStorage.removeItem('gamenight_bound_player');
      window.dispatchEvent(new Event('gamenight-room-left'));
      window.updateRoomNavigation?.(false);
      leaveDialog.close();
      window.showToast('You left the room. Your saved player is kept.');
    }catch(error){leaveError=error instanceof Error?error.message:'Could not leave the room.';}
    finally{leaving=false;}
  }
  async function join() {
    if(document.body.dataset.local!=='true'){window.location.assign('/join');return;}
    await navigate('/studio#join');
    const button=document.getElementById('qr-open');
    const dialog=document.getElementById('qr-scanner') as HTMLDialogElement;
    if(button && dialog && !dialog.open)button.click();
  }
</script>
<nav class="site-nav" aria-label="Main navigation" aria-busy={$busy}>
  <a class="site-logo" href="/"><img src="/web/icon.svg" alt="" width="32" height="32">GameNight</a>
  <div class="site-links">
    <a href="/catalog" aria-current={($route.startsWith('/catalog') || $route.startsWith('/games/'))?'page':undefined}>Games</a>
    <a class="site-desktop-link" href="/docs" aria-current={$route==='/docs' || $route.startsWith('/docs/')?'page':undefined}>Docs</a>
    <a href={$signedIn?'/studio':'/auth/login'} aria-current={$route.startsWith('/studio') && !$route.includes('#session')?'page':undefined}>{$signedIn?'You':'Sign in'}</a>
    <a href="/studio#session" hidden={$room!==true} aria-current={$route==='/studio#session'?'page':undefined}>Playlist</a>
    {#if $room===true && $assistantUrl}
      <a href={$assistantUrl} aria-current={$route==='/agent'?'page':undefined}>Assistant</a>
    {/if}
  </div>
  <div class="site-room-actions">
    <a class="site-host site-desktop-action" href={document.body.dataset.local==='true'?'https://gamenight.ontola.io/host':'/host'} aria-current={$route==='/host'?'page':undefined}>Host</a>
    <button class="btn-primary" data-room-join hidden={$roomJoined!==false} onclick={join}>Join</button>
    <button class="btn-primary site-desktop-action" data-room-leave hidden={$roomJoined!==true} onclick={openLeave}>Leave room</button>
    <button class="site-menu-toggle" aria-label="Open menu" aria-haspopup="dialog" onclick={()=>menuDialog.showModal()}>
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>
    </button>
  </div>
</nav>
<dialog class="site-menu-dialog" aria-labelledby="site-menu-title" bind:this={menuDialog} onclick={(event)=>{if(event.target===menuDialog)menuDialog.close();}}>
  <div class="site-menu-heading"><h2 id="site-menu-title">Menu</h2><button aria-label="Close menu" onclick={()=>menuDialog.close()}>×</button></div>
  <nav aria-label="More navigation">
    <a href="/docs" aria-current={$route==='/docs' || $route.startsWith('/docs/')?'page':undefined} onclick={()=>menuDialog.close()}>Docs <span aria-hidden="true">↗</span></a>
    <a href={document.body.dataset.local==='true'?'https://gamenight.ontola.io/host':'/host'} aria-current={$route==='/host'?'page':undefined} onclick={()=>menuDialog.close()}>Host a room <span aria-hidden="true">→</span></a>
    {#if $roomJoined===true}<button class="site-menu-leave" onclick={openLeave}>Leave room <span aria-hidden="true">→</span></button>{/if}
  </nav>
</dialog>
<dialog class="leave-room-dialog" bind:this={leaveDialog} oncancel={(event)=>{if(leaving)event.preventDefault();}} onclick={(event)=>{if(event.target===leaveDialog && !leaving)leaveDialog.close();}}>
  <section>
    <h2>Leave this room?</h2>
    <p>Your saved player and drawings will stay with you.</p>
    {#if leaveError}<p role="alert">{leaveError}</p>{/if}
    <div class="leave-room-dialog-actions">
      <button disabled={leaving} onclick={()=>leaveDialog.close()}>Stay</button>
      <button class="btn-primary" disabled={leaving} onclick={leave}>{leaving?'Leaving…':'Leave room'}</button>
    </div>
  </section>
</dialog>
