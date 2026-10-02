#!/usr/bin/env python3
"""Headless contract checks for the shared Godot game SDK."""
import argparse,os,shutil,subprocess,tempfile
import http.server,threading,struct,zlib
from pathlib import Path
r=Path(__file__).resolve().parents[1]
a=argparse.ArgumentParser();a.add_argument('--godot',default='godot');args=a.parse_args()
with tempfile.TemporaryDirectory(prefix='gamenight-godot-sdk-') as folder:
 p=Path(folder);shutil.copytree(r/'sdk/godot/addons',p/'addons');shutil.copytree(r/'sdk/godot/tests',p/'tests')
 (p/'idle.tscn').write_text('[gd_scene format=3]\n[node name="Idle" type="Node"]\n')
 (p/'project.godot').write_text('config_version=5\n[application]\nrun/main_scene="res://idle.tscn"\n[autoload]\nGameNight="*res://addons/gamenight/gamenight.gd"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
 env={k:v for k,v in os.environ.items() if not k.startswith('GAMENIGHT')};env['GAMENIGHT_ADDR']='127.0.0.1:1'
 def chunk(kind,data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
 png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\xff\x00\x00'))+chunk(b'IEND',b'')
 class Art(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def do_GET(self):
   self.send_response(200 if self.path=='/cover.png' else 404);self.send_header('Content-Length',str(len(png) if self.path=='/cover.png' else 0));self.end_headers()
   if self.path=='/cover.png': self.wfile.write(png)
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Art)
 threading.Thread(target=server.serve_forever,daemon=True).start()
 env['ART_TEST_URL']=f'http://127.0.0.1:{server.server_port}'
 result=subprocess.run([args.godot,'--headless','--path',str(p),'--script','res://tests/game_contract.gd'],env=env,capture_output=True,text=True,timeout=30)
 server.shutdown();server.server_close()
 print(result.stdout);print(result.stderr)
 assert result.returncode==0 and 'GAME_SDK_PASS' in result.stdout and 'SCRIPT ERROR' not in result.stderr

 # A managed game with no host must exit instead of running unattended/reconnecting.
 env['GAMENIGHT']='1'
 lost=subprocess.run([args.godot,'--headless','--path',str(p),'--quit-after','600'],env=env,capture_output=True,text=True,timeout=5)
 assert lost.returncode==0 and 'SCRIPT ERROR' not in lost.stderr, lost.stderr
 print('PASS managed host loss exits cleanly')
