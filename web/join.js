const form=document.getElementById('join-code-form'),input=document.getElementById('join-code');
const game=new URLSearchParams(location.search).get('game');
if(/^[a-z0-9][a-z0-9-]{0,79}$/.test(game||'')&&!['lobby','demo-game'].includes(game)){
 try{sessionStorage.setItem('gamenight_play_after_join_v1',JSON.stringify({game,expires:Date.now()+3600000}));}catch{}
}
form.onsubmit=event=>{event.preventDefault();const code=input.value.trim().toUpperCase();if(!/^[A-Z2-9]{6}$/.test(code)){document.getElementById('join-error').textContent='Enter the six-character code on the TV.';return;}sessionStorage.setItem('gamenight_room_code',code);location.assign('/studio');};
