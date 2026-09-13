"""Pack the reviewed clubhouse exports. Pillow only; no generation/network calls.
Preserve originals. Remove neutral export matte, nearest-neighbour resize and
slice ledge into existing tile roles. Collision and map geometry are untouched.
"""
from pathlib import Path
from PIL import Image
import numpy as np
ROOT = Path(__file__).resolve().parents[4]
SRC = ROOT / 'docs/art/evening-clubhouse'
OUT = ROOT / 'crates/lobby/assets/themes/clubhouse'
OUT.mkdir(parents=True, exist_ok=True)
NEAREST = Image.Resampling.NEAREST
sheet = Image.open(SRC/'props-source.png').convert('RGBA')
def extract(box, size, name):
    im = sheet.crop(box)
    a = np.array(im)
    # The generator exported a neutral checker matte, not alpha. All selected
    # silhouettes use saturated oak/navy; neutral bright pixels are exterior.
    rgb = a[:,:,:3].astype(int)
    neutral = (rgb.max(2)-rgb.min(2)<65) & (rgb.min(2)>80)
    # Flood only the exterior matte: preserve enclosed window highlights.
    from collections import deque
    h,w=neutral.shape
    todo=deque([(x,0) for x in range(w)]+[(x,h-1) for x in range(w)]+[(0,y) for y in range(h)]+[(w-1,y) for y in range(h)])
    seen=np.zeros((h,w),dtype=bool)
    while todo:
        x,y=todo.popleft()
        if x<0 or y<0 or x>=w or y>=h or seen[y,x] or not neutral[y,x]: continue
        seen[y,x]=True
        todo.extend(((x-1,y),(x+1,y),(x,y-1),(x,y+1)))
    a[seen,3]=0
    im = Image.fromarray(a)
    im = im.crop(im.getbbox()).resize(size, NEAREST)
    im.save(OUT/name)
    return im
extract((250,10,585,518),(64,100),'door.png')
ledge=extract((805,220,1395,360),(96,24),'ledge.png')
extract((155,610,710,950),(208,128),'tv.png')
extract((930,495,1275,985),(96,128),'cupboard.png')
Image.open(SRC/'wall-source.png').convert('RGB').resize((640,384),NEAREST).save(OUT/'wall.png')
# Keep the exact 17x5 grid. Make a separate atlas, used only by the clubhouse.
original = ROOT/'crates/lobby/assets/map/resources/ground_rock.png'
atlas=Image.open(original).convert('RGBA')
# All solid shell cells become timber sampled from the approved ledge face.
wood=sheet.crop((930,249,1122,280)).resize((32,8),NEAREST)
# Quieter timber on the room shell; furniture keeps the richer amber colour.
from PIL import ImageEnhance
wood=ImageEnhance.Brightness(wood).enhance(0.55)
wood=ImageEnhance.Color(wood).enhance(0.65)
plank=Image.new('RGBA',(32,32))
for y in range(0,32,8): plank.paste(wood,(0,y))
wood=plank
for i in range(85):
    atlas.paste(wood,((i%17)*32,(i//17)*32))
# Ledge top coincides with the existing one-way tile top; brackets remain below.
for col,idx in enumerate((44,45,46)):
    tile=Image.new('RGBA',(32,32))
    tile.alpha_composite(ledge.crop((col*32,0,col*32+32,24)),(0,0))
    atlas.paste(tile,((idx%17)*32,(idx//17)*32))
atlas.save(OUT/'terrain.png')
(OUT/'terrain.atlas.yaml').write_text('image: ./terrain.png\ntile_size: [32, 32]\ncolumns: 17\nrows: 5\n')
print('Exported clubhouse wall, door, television, cupboard and terrain atlas')

# Nine-slice the cupboard frame so its corners are never stretched to landscape.
cab=Image.open(OUT/'cupboard.png')
wide=Image.new('RGBA',(228,104))
sx=[0,12,84,96]; sy=[0,15,112,128]
dx=[0,6,222,228]; dy=[0,6,98,104]
for y in range(3):
    for x in range(3):
        patch=cab.crop((sx[x],sy[y],sx[x+1],sy[y+1]))
        wide.paste(patch.resize((dx[x+1]-dx[x],dy[y+1]-dy[y]),NEAREST),(dx[x],dy[y]))
wide.save(OUT/'cabinet-wide.png')
