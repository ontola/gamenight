<script lang="ts">
  import { room, route, busy } from './state';
  import { navigate } from './router';
  let leaveDialog: HTMLDialogElement;
  let leaving = false;
  let leaveError = '';
  async function leave() {
    leaving=true; leaveError='';
    try {
      const local=document.body.dataset.local==='true';
      let path='/v1/pairing/unlink';
      const headers: Record<string,string>={'Content-Type':'application/json'};
      if(local){
        const player=localStorage.getItem('gamenight_bound_player');
        if(!player)throw Error('Open You to refresh your controller connection, then try again.');
        path='/api/player-links/'+encodeURIComponent(player)+'/unlink';
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
    await navigate('/studio#join');
    const button=document.getElementById('qr-open');
    const dialog=document.getElementById('qr-scanner') as HTMLDialogElement;
    if(button && dialog && !dialog.open)button.click();
  }
</script>
<nav class="site-nav" aria-label="Main navigation" aria-busy={$busy}>
  <a class="site-logo" href="/"><img src="/web/icon.svg" alt="" width="32" height="32">GameNight</a>
  <div class="site-links">
    <a href="/" aria-current={$route==='/'?'page':undefined}>Home</a>
    <a href="/catalog" aria-current={$route.startsWith('/catalog')?'page':undefined}>Games</a>
    <a href="/studio" aria-current={$route.startsWith('/studio') && !$route.includes('#session')?'page':undefined}>You</a>
    <a href="/studio#session" hidden={$room!==true} aria-current={$route==='/studio#session'?'page':undefined}>Playlist</a>
  </div>
  <div class="site-room-actions">
    <button class="btn-primary" data-room-join hidden={$room!==false} onclick={join}>Join</button>
    <button class="btn-primary" data-room-leave hidden={$room!==true} onclick={()=>{leaveError='';leaveDialog.showModal();}}>Leave room</button>
  </div>
</nav>
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
