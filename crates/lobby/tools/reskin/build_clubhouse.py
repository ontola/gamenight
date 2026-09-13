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
wall=Image.open(SRC/'wall-source-v2.png').convert('RGBA')
# Place extracted window frames inside the playable room, not behind its side
# colliders. Restore the original frame locations with quiet wall from the same
# export; this is deterministic compositing of reviewed artwork.
for box,position in [((33,400,127,530),(195,590)),((1492,400,1585,530),(1320,590))]:
    frame=wall.crop(box)
    frame.paste((0,0,0,0),(15,16,box[2]-box[0]-14,107))
    wall.paste(wall.crop((box[0],340,box[2],390)).resize(frame.size,NEAREST),(box[0],box[1]))
    wall.paste(frame,position)
wall=wall.resize((640,384),NEAREST)
# House exterior matches solid side walls x=32..1248 and y=32..736.
# Keep outside pixels transparent: the landscape, not enlarged wallpaper,
# fills the surrounding screen. Use the approved oak ledge as a roof fascia.
house=Image.new('RGBA',(640,384))
house.paste(wall.crop((16,16,624,336)),(16,16))
fascia=ledge.crop((4,0,92,7)).resize((608,7),NEAREST)
house.alpha_composite(fascia,(16,16))
house.save(OUT/'wall.png')
sky=Image.open(SRC/'skyline-source.png').convert('RGB')
# Frame the roofline through the small windows, not just empty upper sky.
sky.resize((640,384),NEAREST).save(OUT/'skyline.png')
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
atlas.paste(Image.new('RGBA',(32,32)),((84%17)*32,(84//17)*32))
# Thin floor cap, with all remaining collider art transparent.
floor_tile=Image.new('RGBA',(32,32))
floor_tile.paste(wood.crop((0,0,32,4)),(0,0))
atlas.paste(floor_tile,((83%17)*32,(83//17)*32))
# Duplicate each cell's edge texels into a one-pixel gutter. Smooth camera
# scaling must never sample the orange timber from a neighbouring atlas cell.
padded=Image.new('RGBA',(17*34,5*34))
for i in range(85):
    x,y=(i%17)*32,(i//17)*32
    tile=atlas.crop((x,y,x+32,y+32))
    a=np.array(tile)
    gutter=Image.fromarray(np.pad(a,((1,1),(1,1),(0,0)),mode='edge'))
    padded.paste(gutter,((i%17)*34,(i//17)*34))
padded.save(OUT/'terrain.png')
(OUT/'terrain.atlas.yaml').write_text('image: ./terrain.png\ntile_size: [32, 32]\ncolumns: 17\nrows: 5\npadding: [2, 2]\noffset: [1, 1]\n')
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

# Exterior sprites retain generated alpha. Black-matte fallback is restricted
# to export-background pixels (the art uses blue/umber, never pure black).
def exterior(name):
    im=Image.open(SRC/(name+'-source.png')).convert('RGBA')
    a=np.array(im)
    a[(a[:,:,:3].max(2)<8),3]=0
    im=Image.fromarray(a)
    return im.crop(im.getbbox())
exterior('roof').resize((624,48),NEAREST).save(OUT/'roof.png')
ground=exterior('ground').resize((512,128),NEAREST)
strip=Image.new('RGBA',(2048,128))
for x in range(0,2048,512): strip.paste(ground,(x,0))
strip.save(OUT/'ground.png')

exterior('jukebox').resize((280,80),NEAREST).save(OUT/'jukebox.png')
