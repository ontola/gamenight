"use strict";
(async () => {
  const cloud = document.body.dataset.cloud === 'true';
  let csrf, documentState, pendingKey, prefix='';
  const pairing=new URLSearchParams(location.hash.slice(1)).get('pair');
  if(cloud && pairing){sessionStorage.setItem('gamenight_pair',pairing);history.replaceState(null,'',location.pathname);}
  const roomCode=new URLSearchParams(location.hash.slice(1)).get('room');
  if(cloud && roomCode){sessionStorage.setItem('gamenight_room_code',roomCode);history.replaceState(null,'',location.pathname);}
  const nativeStorage=window.localStorage;
  const local={ getItem:k=>nativeStorage.getItem(prefix+k), setItem:(k,v)=>nativeStorage.setItem(prefix+k,v), removeItem:k=>nativeStorage.removeItem(prefix+k) };
  async function request(path,method='GET',body) {
    const response=await fetch(path,{method,headers:{'Content-Type':'application/json',...(csrf?{'X-GameNight-CSRF':csrf}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
    if(response.status===401){location.replace('/auth/login');throw Error('Please sign in.');}
    if(response.status===429)throw Error('Too many attempts. Wait a minute before trying again.');
    if(response.status===409)throw Error('Another device saved changes. Export your work before refreshing; your local copy is kept.');
    if(!response.ok)throw Error('Not synced. Your work is saved on this device; try again when connected.');
    return response.status===204?null:response.json();
  }
  try {
    if(cloud){
      csrf=(await request('/auth/session')).csrf;
      const account=await request('/v1/me'); prefix='cloud:'+account.id+':';pendingKey='pending';
      documentState=await request('/v1/me/studio');
      window.initAccountSettings(account,request);
    }
    window.gamenightStorage={cloud,local,initial:documentState,
      async loadProfile(id){if(cloud)return {username:documentState.profile.display_name,skin_color:documentState.profile.skin_color,avatar:documentState.profile.avatar};const r=await fetch('/api/profiles/'+encodeURIComponent(id));return r.ok?r.json():null;},
      async save(profile,workspace){
        if(!cloud){const r=await fetch('/api/profiles',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(profile)});if(!r.ok)throw Error('Could not save profile');return;}
        const queued=local.getItem(pendingKey);
        const revision=queued?JSON.parse(queued).revision:documentState.revision;
        const payload={revision,profile:{display_name:profile.username,skin_color:profile.skin_color,avatar:profile.avatar},workspace:JSON.parse(workspace)};
        // Keep failed edits under this account's namespace; never silently replay over a newer revision.
        local.setItem(pendingKey,JSON.stringify(payload));
        documentState=await request('/v1/me/studio','PUT',payload);local.removeItem(pendingKey);
      },
      pending:cloud?local.getItem(pendingKey):null
    };
    if(cloud){
      const ticket=sessionStorage.getItem('gamenight_pair');
      if(ticket){
        const box=document.createElement('section');box.className='card';box.setAttribute('aria-live','polite');document.querySelector('main').prepend(box);
        try{
          const info=await request('/v1/pairing/'+encodeURIComponent(ticket));
          const text=document.createElement('p');text.textContent='Connect your player to controller '+(info.seat+1)+' in the lobby you scanned?';
          const button=document.createElement('button');button.className='btn-primary';button.textContent='Connect to lobby';
          button.onclick=async()=>{button.disabled=true;try{await request('/v1/pairing/claim','POST',{ticket});sessionStorage.removeItem('gamenight_pair');text.textContent='Connected. Your saved character updates in this lobby.';button.remove();await checkRoom();}catch(error){text.textContent=error.message;button.disabled=false;}};
          box.append(text,button);
        }catch{sessionStorage.removeItem('gamenight_pair');box.textContent='This lobby link has expired. Scan the QR again.';}
      }
    }
    const roomForm=document.getElementById('room-form'), roomInput=document.getElementById('room-code');
    const roomStatus=document.getElementById('room-status'), roomCancel=document.getElementById('room-cancel');
    const roomLeave=document.getElementById("room-leave"), qrOpen=document.getElementById("qr-open");
    let watching=false, roomTimer, roomEpoch=0;
    function showConnection(state) {
      const connected=state.status==="connected";
      qrOpen.hidden=connected; roomForm.hidden=connected; roomLeave.hidden=!connected;
      roomLeave.textContent=state.room_code ? "Leave room "+state.room_code : "Leave room";
    }
    async function checkRoom(){
      if(!cloud)return;
      clearTimeout(roomTimer);
      const epoch=++roomEpoch;
      try {
        const state=await request('/v1/rooms/status');
        if(epoch!==roomEpoch)return;
        showConnection(state);
        if(state.status==='waiting') {
          watching=true; roomCancel.hidden=false;
          roomStatus.textContent='Walk your unlinked character to your door in the lobby and stand there to connect. Pickup expires in '+Math.max(1,Math.ceil((state.expires-Date.now()/1000)/60))+' minutes.';

        } else {
          roomCancel.hidden=true;
          if(watching)roomStatus.textContent=state.status==='connected'?'Connected! Your saved character now follows your controller.':'Your pickup expired or was cancelled. Enter the room code to try again.';
          watching=false;
        }
      } catch { /* Retain the last known connection on a network failure. */ }
      finally { if(epoch===roomEpoch)roomTimer=setTimeout(checkRoom,3000); }
    }
    roomLeave.addEventListener("click",async()=>{
      roomLeave.disabled=true; ++roomEpoch; clearTimeout(roomTimer);
      try {
        await request("/v1/pairing/unlink","POST",{});
        watching=false; roomCancel.hidden=true; showConnection({status:"none"});
        roomStatus.textContent="You left the room. Your saved player is kept.";
      } catch(error) { roomStatus.textContent=error.message; }
      finally { roomLeave.disabled=false; await checkRoom(); }
    });
    let joiningRoom=false;
    async function joinRoom(){
      const code=roomInput.value.trim().toUpperCase();
      if(joiningRoom || !/^[A-Z2-9]{6}$/.test(code))return;
      if(!cloud){location.href='https://gamenight.ontola.io/studio#room='+encodeURIComponent(code);return;}
      joiningRoom=true;roomInput.readOnly=true;
      roomForm.setAttribute('aria-busy','true');roomStatus.textContent='Joining room…';
      try {
        await request('/v1/rooms/join','POST',{code});
        clearTimeout(roomTimer);watching=true;await checkRoom();
      } catch(error){roomStatus.textContent=error.message.startsWith('Too many')?error.message:'Could not join this room. Check the code and that you are not already connected.';}
      finally{joiningRoom=false;roomInput.readOnly=false;roomForm.setAttribute('aria-busy','false');}
    }
    roomInput.addEventListener('input',()=>{
      roomInput.value=roomInput.value.toUpperCase().replace(/[^A-Z2-9]/g,'').slice(0,6);
      return joinRoom();
    });
    roomForm.addEventListener('submit',event=>{
      event.preventDefault();return joinRoom();
    });
    roomCancel.addEventListener('click',async()=>{
      roomCancel.disabled=true;
      try {await request('/v1/rooms/cancel','POST',{});clearTimeout(roomTimer);watching=false;roomCancel.hidden=true;roomStatus.textContent='Pickup cancelled.';}
      catch(error){roomStatus.textContent=error.message;}
      finally{roomCancel.disabled=false;}
    });
    if(cloud){roomInput.value=sessionStorage.getItem('gamenight_room_code')||'';sessionStorage.removeItem('gamenight_room_code');if(roomInput.value)await joinRoom();else checkRoom();}
    const script=document.createElement('script');script.src='/web/studio.js';document.body.append(script);
  }catch(error){const el=document.createElement('p');el.setAttribute('role','alert');el.textContent=error.message;document.querySelector('main').prepend(el);}
})();
