import { writable } from 'svelte/store';
export const signedIn = writable(document.body.dataset.local==='true');
export const assistantUrl = writable('');
export const room = writable<boolean|null>(null);
export const roomJoined = writable<boolean|null>(null);
export const roomWaiting = writable(false);
export const player = writable(sessionStorage.getItem('gamenight_nav_name') || localStorage.getItem('gamenight_player_name') || 'Your player');
export const route = writable(location.pathname + location.hash);
export const busy = writable(false);
declare global {
  interface Window {
    gamenightRoomConnected?: boolean;
    updateRoomNavigation?: (connected: boolean, waiting?: boolean)=>void;
    updatePlayerNavigation?: (name: string)=>void;
    showToast: (message: string)=>void;
    gamenightNavigate?: (url: string)=>Promise<void>;
  }
}
window.updateRoomNavigation = (connected, waiting = false) => {
  roomJoined.set(connected || waiting);
  roomWaiting.set(waiting);
  const changed=window.gamenightRoomConnected!==connected;
  window.gamenightRoomConnected=connected;
  sessionStorage.setItem('gamenight_room_connected',String(connected));
  room.set(connected);
  if(!connected)assistantUrl.set('');
  if(changed)window.dispatchEvent(new CustomEvent('gamenight-room-change',{detail:{connected}}));
  queueMicrotask(()=>route.set(location.pathname+location.hash));
};
window.updatePlayerNavigation = name => {
  if(name?.trim()){player.set(name.trim());sessionStorage.setItem('gamenight_nav_name',name.trim());}
};
