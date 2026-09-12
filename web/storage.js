"use strict";
(async () => {
  const cloud = document.body.dataset.cloud === 'true';
  let csrf, documentState, pendingKey, prefix='';
  const nativeStorage=window.localStorage;
  const local={ getItem:k=>nativeStorage.getItem(prefix+k), setItem:(k,v)=>nativeStorage.setItem(prefix+k,v), removeItem:k=>nativeStorage.removeItem(prefix+k) };
  async function request(path,method='GET',body) {
    const response=await fetch(path,{method,headers:{'Content-Type':'application/json',...(csrf?{'X-GameNight-CSRF':csrf}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
    if(response.status===401){location.replace('/auth/login');throw Error('Please sign in.');}
    if(response.status===409)throw Error('Another device saved changes. Export your work before refreshing; your local copy is kept.');
    if(!response.ok)throw Error('Not synced. Your work is saved on this device; try again when connected.');
    return response.status===204?null:response.json();
  }
  try {
    if(cloud){
      csrf=(await request('/auth/session')).csrf;
      const account=await request('/v1/me'); prefix='cloud:'+account.id+':';pendingKey='pending';
      documentState=await request('/v1/me/studio');
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
    const script=document.createElement('script');script.src='/web/studio.js';document.body.append(script);
  }catch(error){const el=document.createElement('p');el.setAttribute('role','alert');el.textContent=error.message;document.querySelector('main').prepend(el);}
})();
