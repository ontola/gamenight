"""Disposable real-engine world for live-rule tests; never touches the play world.
Starts two clients with controller input disabled. Stop via the printed root/stop file.
"""
import argparse, json, os, shutil, subprocess, time
from pathlib import Path
from prototype import command, write


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime',type=Path,required=True)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--port',type=int,default=30129)
    a=p.parse_args(); root=a.root.resolve()
    root.mkdir(parents=True,exist_ok=False)
    world=root/'world';world.mkdir()
    write(world/'world.mt','gameid = mineclonia\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\n')
    shutil.copytree(Path(__file__).parent/'mods/gamenight_bridge',world/'worldmods/gamenight_bridge')
    # A fixed test platform lets actual players contact the live pad, without
    # adding teleport/terrain commands to the production adapter.
    write(world/'worldmods/test_platform/mod.conf','name = test_platform\ndepends = gamenight_bridge\n')
    write(world/'worldmods/test_platform/init.lua',"""
core.register_on_joinplayer(function(player)
 core.emerge_area({x=-8,y=-2,z=-8},{x=8,y=5,z=8},function(_,_,remaining)
  if remaining ~= 0 then return end
  core.after(1,function()
   if not player or not player:is_player() then return end
   for x=-6,6 do for z=-6,6 do core.set_node({x=x,y=0,z=z},{name='gamenight_bridge:bounce_pad'}) end end
   player:set_pos({x=player:get_player_name()=='Couch1' and -2 or 2,y=.5,z=0})
  end)
 end)
end)
""")
    write(root/'server.conf',f'bind_address = 127.0.0.1\nport = {a.port}\nserver_announce = false\nmax_users = 2\ndefault_privs = interact,shout\nenable_damage = false\nmg_name = singlenode\n')
    exe=a.runtime.resolve()/'controller-engine-managed/bin/luanti.exe'
    processes=[]; logs=[]
    env={k:v for k,v in os.environ.items() if not k.startswith('GAMENIGHT_')}
    startup=None
    if os.name=='nt':
        startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
    def launch(args,label):
        log=(root/(label+'.log')).open('w');logs.append(log)
        own=dict(env,LUANTI_USER_PATH=str(root/(label+'-user')))
        proc=subprocess.Popen([str(exe),*args],cwd=root,env=own,stdin=subprocess.DEVNULL,stdout=log,stderr=log,startupinfo=startup)
        processes.append(proc);return proc
    try:
        server=launch(['--server','--world',str(world),'--config',str(root/'server.conf')],'server')
        deadline=time.monotonic()+180
        while not (world/'gamenight/status.json').exists():
            assert server.poll() is None,'Server exited; inspect log'
            if time.monotonic()>deadline:raise TimeoutError('World startup')
            time.sleep(.2)
        for i in (1,2):
            conf=root/f'client-{i}.conf'
            write(conf,'fullscreen = false\nscreen_w = 640\nscreen_h = 360\nenable_joysticks = false\nsound_volume = 0\nfps_max = 20\nfps_max_unfocused = 10\nviewing_range = 20\n')
            launch(['--go','--address','127.0.0.1','--port',str(a.port),'--name',f'Couch{i}','--password','isolated-rules-test','--config',str(conf)],f'client-{i}')
        deadline=time.monotonic()+75
        while len(command(root,'status')['state'].get('players') or [])!=2:
            if time.monotonic()>deadline:raise TimeoutError('Two clients did not join')
            time.sleep(.5)
        write(root/'ready.json',json.dumps({'server_pid':server.pid,'client_pids':[p.pid for p in processes[1:]]}))
        print('READY '+str(root),flush=True)
        while not (root/'stop').exists():
            assert all(p.poll() is None for p in processes),'An engine process exited'
            time.sleep(.5)
    finally:
        if processes and processes[0].poll() is None:
            try: command(root,'shutdown');processes[0].wait(timeout=15)
            except (OSError,RuntimeError,TimeoutError,subprocess.TimeoutExpired):pass
        for proc in reversed(processes):
            if proc.poll() is None:proc.terminate();proc.wait(timeout=10)
        for log in logs:log.close()

if __name__=='__main__': main()
