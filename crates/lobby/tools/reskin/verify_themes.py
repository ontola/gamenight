"""Validate themed assets against the unchanged lobby physics and animation contract.
Run with Python, Pillow and PyYAML after build_themes.py.
"""
from pathlib import Path
import yaml
from PIL import Image
ROOT=Path(__file__).resolve().parents[4]
ASSETS=ROOT/'crates/lobby/assets'
base=yaml.safe_load((ASSETS/'map/levels/gamenight_lobby.map.yaml').read_text())
count=0
for theme in ('underwater','sky','school','gameroom'):
    folder=ASSETS/'themes'/theme
    room=yaml.safe_load((folder/'room.map.yaml').read_text())
    for key in ('grid_size','tile_size','layers'):
        assert room[key]==base[key], (theme,'changed gameplay geometry',key)
    background=Image.open(folder/'room.png')
    assert background.size==(640,384)
    for skin in ('fishy','pescy','sharky','orcy'):
        player=yaml.safe_load((folder/skin/'player.player.yaml').read_text())
        original=yaml.safe_load((ASSETS/'player/skins'/skin/(skin+'.player.yaml')).read_text())
        for key in ('body_size','slide_body_size'):
            assert player[key]==original[key], (theme,skin,key)
        for value in player['sounds'].values():
            if isinstance(value,str):
                assert (ASSETS/value.lstrip('/')).is_file(), (theme,skin,'missing sound',value)
        for layer in ('body','face','fin'):
            path=ASSETS/player['layers'][layer]['atlas'].lstrip('/')
            atlas=yaml.safe_load(path.read_text())
            sheet=Image.open(path.parent/atlas['image'])
            w,h=atlas['tile_size']
            assert sheet.size==(w*atlas['columns'],h*atlas['rows'])
            for name,anim in player['layers'][layer]['animations'].items():
                for frame in anim['frames']:
                    idx=frame['idx'] if isinstance(frame,dict) else frame
                    assert 0<=idx<atlas['columns']*atlas['rows'], (theme,skin,layer,name,idx)
        assert player['layers']['face']['atlas']==f'/player/skins/{skin}/{skin}-face.atlas.yaml'
        assert sheet.mode in ('RGBA','P')
        count+=1
print(f'PASS: four rooms, {count} complete outfits, identical colliders and valid animation references')
