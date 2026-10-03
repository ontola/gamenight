"""Build themed room maps and matching player animation atlases.
Source exports are retained in docs/art/lobby-themes. Requires Pillow.
Run after build_pixellab.py; does not overwrite original room or skins.
"""
from pathlib import Path
import re
from PIL import Image
import build_pixellab as base
ROOT = Path(__file__).resolve().parents[4]
ASSETS = ROOT / 'crates/lobby/assets'
SOURCE = ROOT / 'docs/art/lobby-themes'
THEMES = ('underwater', 'sky', 'school', 'gameroom')


def build():
    entries = []
    for theme in THEMES:
        folder = ASSETS / 'themes' / theme
        folder.mkdir(parents=True, exist_ok=True)
        Image.open(SOURCE/theme/'room-source.png').convert('RGBA').resize((640,384),Image.Resampling.NEAREST).save(folder/'room.png')
        map_text = (ASSETS/'map/levels/gamenight_lobby.map.yaml').read_text()
        map_text = map_text.replace('name: GameNight Lobby', 'name: GameNight '+theme.title()).replace('/map/resources/bg_room.png', '/themes/'+theme+'/room.png')
        (folder/'room.map.yaml').write_text(map_text)
        base.SOURCE = SOURCE/theme
        players = []
        for skin,hue in base.SKINS.items():
            dest=folder/skin;dest.mkdir(exist_ok=True)
            stand=base.pose('character-1',hue,center=42)
            frames={i:stand for i in range(98)}
            for action,start in [('walk',14),('sleep',20),('wake',24),('jump',28)]:
                for i in range(4):frames[start+i]=base.pose(action+'-'+str(i),hue,center=42)
            frames[28]=base.pose('jump-2',hue,center=42)
            frames[42]=base.pose('jump-3',hue,center=42)
            frames[56]=frames[58]=base.pose('crouch-3',hue,center=42)
            for start,direction in ((70,1),(84,-1)):
                for i in range(7):frames[start+i]=stand.rotate(direction*i*15,Image.Resampling.NEAREST,center=(48,53))
            sheet=Image.new('RGBA',(1344,560))
            for i,frame in frames.items():sheet.alpha_composite(frame,(i%14*96,i//14*80))
            sheet.save(dest/'body.png')
            (dest/'body.atlas.yaml').write_text('image: ./body.png\ntile_size: [96, 80]\nrows: 7\ncolumns: 14\n')
            text=(ASSETS/'player/skins'/skin/(skin+'.player.yaml')).read_text()
            text=text.replace('../../sounds/', '/player/sounds/')
            text=text.replace(': ./', ': /player/skins/'+skin+'/')
            text=text.replace('/player/skins/'+skin+'/'+skin+'-body.atlas.yaml','/themes/'+theme+'/'+skin+'/body.atlas.yaml')
            (dest/'player.player.yaml').write_text(text)
            players.append('/themes/'+theme+'/'+skin+'/player.player.yaml')
            assert all(sheet.crop((i%14*96,i//14*80,i%14*96+96,i//14*80+80)).getbbox() for i in range(98))
        entries.append('    - id: '+theme+'\n      map: /themes/'+theme+'/room.map.yaml\n      players:\n'+''.join('        - '+p+'\n' for p in players))
        print('Built',theme,'with four animated outfits')
    game=ASSETS/'game.yaml';text=game.read_text()
    text=re.sub(r'  lobby_themes:\n.*?(?=\n  [^ #])','',text,flags=re.S)
    marker='  lobby_map: /map/levels/gamenight_lobby.map.yaml\n'
    assert marker in text
    text=text.replace(marker, marker+'\n  lobby_themes:\n'+''.join(entries))
    game.write_text(text)

if __name__ == '__main__': build()
