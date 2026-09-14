const form=document.getElementById('join-code-form'),input=document.getElementById('join-code');
form.onsubmit=event=>{event.preventDefault();const code=input.value.trim().toUpperCase();if(!/^[A-Z2-9]{6}$/.test(code)){document.getElementById('join-error').textContent='Enter the six-character code on the TV.';return;}sessionStorage.setItem('gamenight_room_code',code);location.assign('/studio');};
