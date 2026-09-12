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
      async playlist(change) {
        if (!cloud) {
          const profile=local.getItem('gamenight_profile_id');
          const linked=profile && await fetch('/api/profiles/'+encodeURIComponent(profile)+'/session',{cache:'no-store',signal:AbortSignal.timeout(10000)});
          if(!linked || !linked.ok || !(await linked.json()).linked){
            window.updateRoomNavigation?.(false);
            throw Error('Join a room to manage its playlist.');
          }
          const response=await fetch('/api/playlist',{cache:'no-store',signal:AbortSignal.timeout(10000),...(change?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(change)}:{})});
          if(!response.ok)throw Error('Playlist unavailable or changed. Refresh and try again.');
          return response.json();
        }
        const view = room => {
          if(room.status!=='connected')throw Error('Join a room to manage its playlist.');
          if(!room.fresh || !room.discovery?.playlist)throw Error('Waiting for your lobby to connect.');
          return {playlist:room.discovery.playlist,playing:room.discovery.current,next:room.discovery.next};
        };
        if(!change)return view(await request('/v1/rooms/status'));
        const id=crypto.randomUUID();
        await request('/v1/rooms/next','POST',{edit:change,request_id:id});
        for(let attempt=0;attempt<12;attempt++) {
          await new Promise(resolve=>setTimeout(resolve,1000));
          const room=await request('/v1/rooms/status');
          if(room.discovery?.acknowledged===id)return view(room);
          if(room.selection?.id && room.selection.id!==id)throw Error('Another player changed the queue. Refresh and try again.');
        }
        throw Error('Your host has not confirmed the change. Refresh before trying again.');
      },
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
        const box=document.createElement('dialog');box.className='pairing-confirmation';
        box.setAttribute('aria-labelledby','pairing-title');
        const panel=document.createElement('div');panel.className='pairing-content';
        const close=document.createElement('button');close.className='icon-btn pairing-close';close.textContent='×';close.setAttribute('aria-label','Cancel joining room');
        const title=document.createElement('h1');title.id='pairing-title';title.textContent='Join this room?';
        const text=document.createElement('p');text.textContent='Checking your room…';text.setAttribute('role','status');
        const button=document.createElement('button');button.className='btn-primary';button.textContent='Accept';button.disabled=true;
        let accepting=false;
        const dismiss=()=>{if(accepting)return;sessionStorage.removeItem('gamenight_pair');box.close();box.remove();document.getElementById('qr-open').focus();};
        close.onclick=dismiss;
        box.addEventListener('cancel',event=>{event.preventDefault();dismiss();});
        panel.append(close,title,text,button);box.append(panel);document.body.append(box);box.showModal();close.focus();
        try{
          const info=await request('/v1/pairing/'+encodeURIComponent(ticket));
          text.textContent='Your saved character will connect to player '+(info.seat+1)+' in the room you scanned.';
          button.disabled=false;
          button.onclick=async()=>{
            if(accepting)return;accepting=true;button.disabled=true;close.disabled=true;text.textContent='Joining room…';
            try{await request('/v1/pairing/claim','POST',{ticket});sessionStorage.removeItem('gamenight_pair');box.close();box.remove();window.showToast('Connected to the room.');await checkRoom();document.getElementById('room-leave').focus();}
            catch(error){window.showToast(error.message);text.textContent='Could not connect. You can try again or close this screen.';button.disabled=false;close.disabled=false;}
            finally{accepting=false;}
          };
        }catch{sessionStorage.removeItem('gamenight_pair');title.textContent='Room link expired';text.textContent='Close this screen and scan the lobby QR again.';button.hidden=true;}
      }
    }
    const roomForm=document.getElementById('room-form'), roomInput=document.getElementById('room-code');
    const roomStatus=document.getElementById('room-status'), roomCancel=document.getElementById('room-cancel');
    const roomLeave=document.getElementById("room-leave"), qrOpen=document.getElementById("qr-open");
    // Offline rooms are reached by their LAN QR; hosted room codes must not
    // unexpectedly navigate a local editing session to the hosted site.
    roomForm.hidden=false;
    let watching=false, roomTimer, roomEpoch=0;
    function showConnection(state) {
      const connected=state.status==="connected";
      window.updateRoomNavigation?.(connected);
      qrOpen.hidden=connected; roomForm.hidden=connected; roomLeave.hidden=!connected;
      if(connected)document.getElementById('qr-scanner')?.close();
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
          roomCancel.hidden=false;
          if(!watching)window.showToast('Walk your unlinked character to your door in the lobby and stand there to connect. Pickup expires in '+Math.max(1,Math.ceil((state.expires-Date.now()/1000)/60))+' minutes.');
          watching=true;

        } else {
          roomCancel.hidden=true;
          if(watching)window.showToast(state.status==='connected'?'Connected! Your saved character now follows your controller.':'Your pickup expired or was cancelled. Enter the room code to try again.');
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
        window.showToast("You left the room. Your saved player is kept.");
      } catch(error) { window.showToast(error.message); }
      finally { roomLeave.disabled=false; await checkRoom(); }
    });
    function renderRoomCode(){
      Array.from(document.getElementById("room-code-slots").children).forEach((slot,i)=>{slot.textContent=roomInput.value[i]||"·";});
    }
    let joiningRoom=false;
    async function joinRoom(){
      const code=roomInput.value.trim().toUpperCase();
      if(joiningRoom || !/^[A-Z2-9]{6}$/.test(code))return;
      joiningRoom=true;roomInput.readOnly=true;
      roomForm.setAttribute('aria-busy','true');window.showToast('Joining room…');
      try {
        if(cloud)await request('/v1/rooms/join','POST',{code});
        else {
          const profile=local.getItem('gamenight_profile_id');
          const saved=local.getItem('gamenight_saved_profile');
          if(!profile || !saved)throw Error('Open You to create your player first.');
          await request('/api/profiles','POST',JSON.parse(saved));
          await request('/api/local-room/join','POST',{code,profile});
          roomCancel.hidden=false;
          window.showToast('Walk your character to your profile door in the lobby to connect.');
        }
        document.getElementById('qr-scanner')?.close();
        clearTimeout(roomTimer);await checkRoom();
      } catch(error){window.showToast(error.message.startsWith('Too many')?error.message:'Could not join this room. Check the code and that you are not already connected.');}
      finally{joiningRoom=false;roomInput.readOnly=false;roomForm.setAttribute('aria-busy','false');}
    }
    roomInput.addEventListener('input',()=>{
      roomInput.value=roomInput.value.toUpperCase().replace(/[^A-Z2-9]/g,'').slice(0,6);
      renderRoomCode();return joinRoom();
    });
    roomForm.addEventListener('submit',event=>{
      event.preventDefault();return joinRoom();
    });
    roomCancel.addEventListener('click',async()=>{
      roomCancel.disabled=true;
      try {await request(cloud?'/v1/rooms/cancel':'/api/local-room/cancel/'+encodeURIComponent(local.getItem('gamenight_profile_id')),'POST',{});clearTimeout(roomTimer);watching=false;roomCancel.hidden=true;window.showToast('Pickup cancelled.');}
      catch(error){window.showToast(error.message);}
      finally{roomCancel.disabled=false;}
    });
    if(cloud){roomInput.value=sessionStorage.getItem('gamenight_room_code')||'';sessionStorage.removeItem('gamenight_room_code');renderRoomCode();if(roomInput.value)await joinRoom();else checkRoom();}
    const script=document.createElement('script');script.src='/web/studio.js';document.body.append(script);
  }catch(error){const el=document.createElement('p');el.setAttribute('role','alert');el.textContent=error.message;document.querySelector('main').prepend(el);}
})();
