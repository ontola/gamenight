// Run only against a fresh, isolated Windows installation. Requires Node 22+.
import fs from 'node:fs';
const ids=['neon-trails','blast-party','neon-siege','ricochet-club','paint-rush','volley-trouble','stack-together','bubble-buddies'];
const results=[]; let party; let failure; let ws;
const endpoint=process.argv[2] || 'ws://127.0.0.1:7912';
const deadline=Date.now()+30000;
while(Date.now()<deadline){
 ws=new WebSocket(endpoint);
 const opened=await new Promise(resolve=>{const timer=setTimeout(()=>resolve(false),2000);ws.addEventListener('open',()=>{clearTimeout(timer);resolve(true);},{once:true});ws.addEventListener('error',()=>{clearTimeout(timer);resolve(false);},{once:true});});
 if(opened)break;
 ws.close();await new Promise(resolve=>setTimeout(resolve,250));
}
ws.addEventListener('message', e=>{ const m=JSON.parse(e.data); if(m.party) party=m.party; if(m.type==='error') failure=m.message; });
const send=m=>ws.send(JSON.stringify(m));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(test,label,timeout=120000){const start=Date.now();while(!test()){if(failure)throw Error(failure);if(Date.now()-start>timeout)throw Error('Timeout: '+label+' '+JSON.stringify({active:party?.active_session,warm:party?.warm_session,installs:party?.installs}));await sleep(100);}}
try {
 await until(()=>ws.readyState===1,'connect',10000);send({type:'hello',role:'overlay'});await until(()=>party,'welcome',10000);
 if(party.players.length) throw Error('Refusing to change a nonempty user party; launch an isolated installation first');
 send({type:'assign_seat',seat:0,occupant:{kind:'ai'}});send({type:'assign_seat',seat:1,occupant:{kind:'ai'}});
 await until(()=>ids.every(id=>party.library.some(g=>g.id===id)),'all downloadable games installed',240000);
 results.push({check:'all eight games installed',pass:true});
 for(const id of ids){
   send({type:'play_next',game:id});
   await until(()=>party.warm_session?.game===id && party.warm_session.phase==='ready','preload '+id);
   send({type:'next'});send({type:'close_overlay'});
   await until(()=>party.active_session?.game===id && party.active_session.phase==='running','start '+id);
   await sleep(2000);send({type:'open_overlay'});
   await until(()=>party.active_session?.phase==='paused','pause '+id,10000);
   send({type:'close_overlay'});await until(()=>party.active_session?.phase==='running','resume '+id,10000);
   results.push({game:id,pass:true,checks:['download','prepare','start','pause','resume']});console.log('PASS',id);
 }
 send({type:'open_overlay'});
} catch(e){results.push({pass:false,error:String(e)});console.error(e);process.exitCode=1;} finally {fs.writeFileSync(process.argv[3]||'download-e2e.json',JSON.stringify(results,null,2));ws.close();}
