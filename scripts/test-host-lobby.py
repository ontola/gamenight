#!/usr/bin/env python3
"""Exercise native lobby preferences and public pairing through the real HTTP server."""
import json,os,signal,sys,subprocess,socket,tempfile,time,urllib.request,urllib.error
from pathlib import Path
root=Path(__file__).resolve().parents[1]
target=Path(os.environ.get("CARGO_TARGET_DIR",root/"target"))/"debug"/("gamenight-daemon.exe" if os.name=="nt" else "gamenight-daemon")
with tempfile.TemporaryDirectory(prefix='gamenight-host-ui-') as folder:
 p=Path(folder);config=p/'selected-lobby.json';games=p/'local-games.json';shelf=p/'games.json'
 games.write_text(json.dumps([{'id':'living-room','title':'Living Room','launch':{'command':sys.executable,'env':{'GAMENIGHT_LOBBY_API':'1'}}}]))
 shelf.write_text('[]')
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 with socket.socket() as s:s.bind(('127.0.0.1',0));service_port=s.getsockname()[1]
 env={k:v for k,v in os.environ.items() if not k.startswith('GAMENIGHT')}
 env.update(GAMENIGHT_ADDR=f'127.0.0.1:{port}',GAMENIGHT_HOST_SERVICES_ADDR=f'127.0.0.1:{service_port}',GAMENIGHT_LIBRARY=str(shelf),GAMENIGHT_HOST_SERVICES='1',GAMENIGHT_OFFLINE='1',GAMENIGHT_PLAYER_MEMORY=str(p/'memory.json'),GAMENIGHT_NO_LOBBY_WATCH='1',GAMENIGHT_NO_PREWARM='1',GAMENIGHT_NO_MUSIC='1',GAMENIGHT_LOBBY_CONFIG=str(config),GAMENIGHT_LOCAL_GAMES=str(games))
 with (p/'server.log').open('w') as log:
  options={"creationflags":subprocess.CREATE_NEW_PROCESS_GROUP} if os.name=="nt" else {"start_new_session":True}
  proc=subprocess.Popen([os.environ.get("GAMENIGHT_TEST_DAEMON",str(target))],env=env,stdout=log,stderr=log,**options)
  try:
   base=f'http://127.0.0.1:{service_port}'
   for attempt in range(100):
    try: urllib.request.urlopen(base+'/api/host/lobby',timeout=1);break
    except Exception: time.sleep(.1)
   def call(path,data=None,header=True):
    headers={'Content-Type':'application/json'}
    if header:headers['X-GameNight-Host']='1'
    req=urllib.request.Request(base+path,data=json.dumps(data).encode() if data is not None else None,headers=headers)
    try:
     with urllib.request.urlopen(req,timeout=5) as r:return r.status,r.read()
    except urllib.error.HTTPError as e:return e.code,e.read()
   status,body=call('/api/host/lobby');assert status==200 and len(json.loads(body)['choices'])==2
   assert call('/api/host/lobby',{'id':'living-room'},False)[0]==403
   assert call('/api/host/lobby',{'id':'unknown'})[0]==400
   assert call('/api/host/lobby',{'id':'living-room'})[0]==204
   assert json.loads(config.read_text())['id']=='living-room'
   assert call('/api/host/recovery',{'action':'retry'},False)[0]==403
   assert call('/api/host/recovery',{'action':'retry'})[0]==409
   status,body=call('/api/player-links');assert status==200
   room=json.loads(body)['room'];assert room['room_code']=='' and 'join_url' not in room,room
   for path in ['/', '/studio', '/host/lobby', '/docs', '/onboarding']:
    assert call(path)[0]==404,path
   assert call('/api/host/lobby',{'id':'lobby'})[0]==204
   assert json.loads(config.read_text())['id']=='lobby'
   print('PASS live host preferences, protected native controls and no local pages')
  finally:
   if proc.poll() is None:
    if os.name=='nt':subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True)
    else:os.killpg(proc.pid,signal.SIGTERM)
    proc.wait(timeout=5)
