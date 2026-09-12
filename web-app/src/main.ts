import { mount } from 'svelte';
import Navigation from './Navigation.svelte';
import { startRouter, navigate } from './router';
import './toast.js';
import './state';
const shell=document.getElementById('site-shell');
if(shell){
  startRouter();
  shell.replaceChildren();
  mount(Navigation,{target:shell});
  const scannedRoom=new URLSearchParams(location.search).get('r');
  if(scannedRoom && /^[A-Z2-9]{6}$/.test(scannedRoom)){
    sessionStorage.setItem('gamenight_room_code',scannedRoom);
    void navigate('/studio');
  }
  const local=document.body.dataset.local==='true' || (document.body.classList.contains('studio-page') && document.body.dataset.cloud!=='true');
  if(local)document.body.dataset.local='true';
  async function refreshRoom(){
    try{
      const id=localStorage.getItem('gamenight_profile_id');
      if(local && !id){window.updateRoomNavigation?.(false);return;}
      const response=await fetch(local?'/api/profiles/'+encodeURIComponent(id!)+'/session':'/v1/rooms/status',{cache:'no-store',signal:AbortSignal.timeout(10000)});
      if(response.status===401){window.updateRoomNavigation?.(false);return;}
      if(!response.ok)return;
      const state=await response.json();
      window.updateRoomNavigation?.(local?!!state.linked:state.status==='connected');
    }catch{ /* Keep known state during a transient network failure. */ }
  }
  void refreshRoom();
  setInterval(()=>{if(!document.hidden)void refreshRoom();},3000);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)void refreshRoom();});
}
