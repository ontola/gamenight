'use strict';
let account, csrf;
const $ = id => document.getElementById(id);
function message(text) { $('status').textContent=text; }
async function api(path,method='GET',body) {
 const response=await fetch(path,{method,headers:{'Content-Type':'application/json',...(csrf?{'X-GameNight-CSRF':csrf}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 if(response.status===409) throw new Error('Changed on another device. Refresh to load the latest profile before saving; your unsaved input is still here.');
 if(!response.ok) throw new Error(response.status===401?'Please sign in again.':'Could not save. Your changes are still here.');
 return response.status===204?null:response.json();
}
async function load(){
 try{const session=await api('/auth/session');csrf=session.csrf;account=await api('/v1/me');$('name').value=account.profile.display_name;$('skin').value=account.profile.skin_color;$('personalization').checked=account.preferences.personalization;$('account').hidden=false;message('Signed in. Your profile follows you across devices.');}
 catch{message('Sign in to save your player profile.');$('login').hidden=false;}
}
$('profile').onsubmit=async event=>{event.preventDefault();const button=event.submitter;button.disabled=true;try{const result=await api('/v1/me/profile','PUT',{revision:account.profile_revision,profile:{...account.profile,display_name:$('name').value,skin_color:$('skin').value}});account.profile=result.profile;account.profile_revision=result.revision;message('Profile saved.');}catch(e){message(e.message);}finally{button.disabled=false;}};
$('personalization').onchange=async()=>{const enabled=$('personalization').checked;$('personalization').disabled=true;try{account.preferences=await api('/v1/me/preferences','PUT',{...account.preferences,personalization:enabled});message(enabled?'Personalisation enabled.':'Personalisation off. Preferences cleared.');}catch(e){$('personalization').checked=!enabled;message(e.message);}finally{$('personalization').disabled=false;}};
$('export').onclick=async()=>{try{const latest=await api('/v1/me');const url=URL.createObjectURL(new Blob([JSON.stringify(latest)],{type:'application/json'}));const link=document.createElement('a');link.href=url;link.download='gamenight-profile.json';link.click();setTimeout(()=>URL.revokeObjectURL(url),30000);}catch(e){message(e.message);}};
$('import').onchange=async()=>{try{const file=$('import').files[0];if(!file)return;if(file.size>65536)throw new Error('This profile file is too large.');const data=JSON.parse(await file.text());if(!data.profile||typeof data.profile.avatar!=='string'||typeof data.profile.display_name!=='string'||!/^#[0-9a-f]{6}$/i.test(data.profile.skin_color))throw new Error('Choose a GameNight cloud profile export.');const result=await api('/v1/me/profile','PUT',{revision:account.profile_revision,profile:{display_name:data.profile.display_name,skin_color:data.profile.skin_color,avatar:data.profile.avatar}});account.profile=result.profile;account.profile_revision=result.revision;$('name').value=result.profile.display_name;$('skin').value=result.profile.skin_color;message('Profile imported.');}catch(e){message(e.message);}finally{$('import').value='';}};
$('logout').onclick=async()=>{try{await api('/v1/session','DELETE');location.reload();}catch(e){message(e.message);}};
$('delete').onclick=async()=>{if(!confirm('Delete your cloud profile, preferences and sessions?'))return;try{await api('/v1/me','DELETE');location.reload();}catch(e){message(e.message);}};
load();

$('unlink').onclick=async()=>{try{await api('/v1/pairing/unlink','POST',{});message('Lobbies disconnected. Your artwork stays in your account.');}catch(e){message(e.message);}};
