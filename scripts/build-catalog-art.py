"""Build offline lobby artwork from actual gameplay captures, never game colors.

Usage: python scripts/build-catalog-art.py --captures <LOVE save directory>
The checked-in PNGs are the source for republishing; --embed refreshes metadata.
Illustrated masters are exported to runtime sizes when present; screenshots stay real.
Requires Pillow. Outputs fit the protocol's 256 KiB / 1024px artwork limits.
"""
import argparse, base64, json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps
ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
 'neon-trails': 'gamenight-love-party/catalog-neon-trails.png',
 'blast-party': 'gamenight-love-party/catalog-blast-party.png',
 'neon-siege': 'gamenight-love-party/catalog-neon-siege.png',
 'ricochet-club': 'gamenight-love-party/catalog-ricochet-club.png',
 'paint-rush': 'gamenight-love-party/catalog-paint-rush.png',
 'volley-trouble': 'volley-trouble/preview-beach.png',
 'stack-together': 'gamenight-coop-arcade/preview-stack.png',
 'bubble-buddies': 'gamenight-coop-arcade/preview-bubbles.png',
 'pinpals': 'pinpals/shot-240.png',
}
# Tiny game-specific glyphs derived from the games' mechanics. Palette stays
# shared across the icon family; a publisher can replace any PNG independently.
def icon(game):
 im=Image.new('RGBA',(32,32),(15,21,34,255));d=ImageDraw.Draw(im)
 ink='#e5ecf5';accent='#6be4d7'
 if game=='neon-siege': d.polygon([(16,4),(27,26),(16,21),(5,26)],outline=accent,width=2)
 elif game=='neon-trails': d.line([(5,25),(5,10),(15,10),(15,20),(26,20),(26,5)],fill=accent,width=4)
 elif game=='blast-party':
  d.ellipse((5,11,23,29),fill=ink);d.line([(18,12),(20,6),(26,6)],fill=accent,width=2);d.rectangle((25,3,28,6),fill='#ffc565')
 elif game in ('volley-trouble','bubble-buddies'):
  for box in ([(5,5,27,27)] if game=='volley-trouble' else [(3,3,17,17),(14,13,29,28),(4,22,10,28)]):d.ellipse(box,outline=accent,width=2)
  if game=='volley-trouble':d.arc((7,5,22,27),-80,90,fill=ink,width=2);d.line([(7,21),(25,12)],fill=ink,width=2)
 elif game=='stack-together':
  for x,y in [(5,21),(14,21),(14,12),(23,12)]:d.rectangle((x,y,x+7,y+7),fill=accent)
 elif game=='paint-rush':d.polygon([(16,3),(6,20),(7,26),(16,29),(25,26),(26,20)],fill=accent)
 elif game=='ricochet-club':d.line([(4,26),(15,12),(28,23)],fill=accent,width=2);d.ellipse((12,8,18,14),fill=ink)
 else:d.rectangle((6,24,26,28),fill=accent);d.ellipse((12,6,20,14),fill=ink)
 return im.resize((64,64),Image.Resampling.NEAREST)

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--captures',type=Path);ap.add_argument('--embed',action='store_true');a=ap.parse_args()
 if not a.captures and not a.embed:ap.error('supply --captures or --embed')
 font=ImageFont.truetype(str(ROOT/'crates/lobby/assets/ui/FairfaxSM.ttf'),22)
 for game,source in SOURCES.items():
  meta_path=ROOT/'catalog/games'/f'{game}.json';meta=json.loads(meta_path.read_text(encoding="utf-8"));out=ROOT/'catalog/art'/game;out.mkdir(parents=True,exist_ok=True)
  if a.captures:
   shot=Image.open(a.captures/source).convert('RGB');shot.thumbnail((512,320));shot.save(out/'screenshot.png',optimize=True)
   cover=ImageOps.fit(shot,(216,288),method=Image.Resampling.LANCZOS)
   d=ImageDraw.Draw(cover);d.rectangle((0,206,216,288),fill='#0f1522')
   words=meta['title'].upper().split();lines=[];line=''
   for word in words:
    candidate=(line+' '+word).strip()
    if d.textlength(candidate,font=font)>190 and line:lines.append(line);line=word
    else:line=candidate
   lines.append(line)
   for i,line in enumerate(lines):d.text((12,216+i*25),line,font=font,fill='#f4f7ff')
   cover.save(out/'cover.png',optimize=True);icon(game).save(out/'icon.png',optimize=True)
  for field in ('cover','icon','screenshot'):
   asset=out/f'{field}.png'
   master=out/f'{field}-illustrated-source.png'
   if field != 'screenshot' and master.exists():
    asset=out/f'{field}-illustrated.png'
    size=(288,384) if field=='cover' else (64,64)
    with Image.open(master) as original:
     exported=ImageOps.contain(original.convert('RGB'),size,method=Image.Resampling.LANCZOS)
     exported.save(asset,optimize=True)
   data=asset.read_bytes();assert len(data)<=256*1024
   with Image.open(asset) as check: assert max(check.size)<=1024
   meta[field]='data:image/png;base64,'+base64.b64encode(data).decode()
  meta.pop('color',None)
  meta_path.write_text(json.dumps(meta,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
  print(game)
if __name__=='__main__':main()
