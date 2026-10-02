-- Exercise the same declaration/change path as the host, then check gameplay.
local U=require('shared.util')
local Lifecycle=require('shared.lifecycle')
local coop=require('games.coop')
local games={require('games.trails'),require('games.blast'),require('games.siege'),require('games.ricochet'),require('games.volley'),coop(require('games.coop.stack')),coop(require('games.coop.bubbles')),require('games.pinpals')}
local function roster() return {{slot=1,name='A',score=0},{slot=2,name='B',score=0}} end
local idle={{x=0,y=0},{x=0,y=0}}
local function defaults(game) for _,spec in ipairs(game.settings) do assert(game.setting(spec.key,spec.default)) end end
for _,game in ipairs(games) do
 assert(#game.settings>0,game.id..' must expose settings')
 local sent={}
 local bridge=Lifecycle.new({send=function(_,m) sent[#sent+1]=m end},{hide=function()end,settings=game.settings,setting=game.setting},game.id)
 bridge:receive({type='welcome',protocol_version=1})
 assert(sent[1].type=='declare_settings' and sent[1].settings==game.settings)
 assert(not game.setting('unknown',true))
 for _,spec in ipairs(game.settings) do
  local old=game.preferences()
  local changed=spec.kind=='toggle' and not spec.default or spec.kind=='choice' and spec.options[#spec.options] or spec.max
  if spec.kind=='toggle' then changed=not spec.default end
  bridge:receive({type='setting_changed',key=spec.key,value=changed})
  assert(game.preferences()[spec.key]==changed,game.id..':'..spec.key)
  assert(old[spec.key]==spec.default,'preferences must be a snapshot')
  assert(not game.setting(spec.key,{}))
  if spec.kind=='number' then
   for _,bad in ipairs({spec.min-1,spec.max+1,spec.min+.5,math.huge,'2'}) do assert(not game.setting(spec.key,bad)) end
   assert(not game.setting(spec.key,0/0))
  elseif spec.kind=='choice' then assert(not game.setting(spec.key,'not-an-option'))
  else assert(not game.setting(spec.key,1)) end
  assert(game.preferences()[spec.key]==changed,'invalid change must preserve last accepted value')
  assert(game.setting(spec.key,spec.default))
 end
 print('PASS settings declaration, routing and validation: '..game.id)
end
local trails=games[1]
local slow=trails.new(roster(),U.rng(1))
trails.setting('speed',175)
local fast=trails.new(roster(),U.rng(1))
trails.update(slow,.08,idle);trails.update(fast,.08,idle)
assert(slow.players[1].x==8 and fast.players[1].x==9)
trails.setting('round_pause','3.0 s')
-- Existing round stays unchanged, following round picks up both preferences.
slow.players[1].alive=false;trails.update(slow,.11,idle)
assert(slow.intermission==1.4)
trails.update(slow,1.5,idle);slow.players[1].alive=false;trails.update(slow,.11,idle)
assert(slow.intermission==3)
defaults(trails)
local blast=games[2]
blast.setting('pickups',0);blast.setting('fuse','1.0 s')
local bombs=blast.new(roster(),U.rng(1))
assert(next(bombs.drops)==nil)
blast.placeBomb(bombs,bombs.players[1]);assert(bombs.bombs[1].fuse==1)
blast.setting('fuse','4.0 s');assert(bombs.bombs[1].fuse==1)
local function crates(density)
 blast.setting('crates',density)
 local count=0
 for seed=1,20 do local tiles=blast.generate(U.rng(seed));for _,tile in pairs(tiles) do if tile=='crate' then count=count+1 end end end
 return count
end
assert(crates(85)>crates(20));defaults(blast)
local siege=games[3];local gravity=require('games.siege_gravity');local waves=require('games.siege_waves')
siege.setting('gravity',0);siege.setting('wormholes',false)
local space=siege.new(roster(),U.rng(1));space.wave=6;space.time=10
assert(#gravity.fields(space)==0 and #gravity.portals(space)==0)
siege.setting('gravity',150);siege.setting('wormholes',true)
assert(#gravity.fields(space)==0,'running round must retain its settings')
space=siege.new(roster(),U.rng(1));space.wave=6;space.time=10
assert(#gravity.fields(space)==2 and #gravity.portals(space)==2)
assert(#waves.plan(2,2,1280,720,'intense')>#waves.plan(2,2,1280,720,'relaxed'));defaults(siege)
local tanks=games[4];tanks.setting('cover',false);tanks.setting('bounces',0);tanks.setting('shot_speed',150)
local arena=tanks.new(roster(),U.rng(1));assert(#arena.cover==0)
local p=arena.players[1]
arena.shots={{x=1200,y=400,vx=430,vy=0,owner=p,ttl=2,bounces=0}}
tanks.update(arena,.02,idle);assert(#arena.shots==0,'zero ricochets removes a wall hit')
defaults(tanks)
local volley=games[5];volley.setting('target',3);volley.setting('arena','lava')
local court=volley.new(roster());assert(court.target==3 and court.arena=='lava');defaults(volley)
local stack=games[6];stack.setting('target',4)
assert(stack.new(roster()).target==4);defaults(stack)
local bubbles=games[7];bubbles.setting('hearts',2);bubbles.setting('wave_seconds',30);bubbles.setting('waves',1)
local bubble=bubbles.new(roster());assert(bubble.hearts==2 and bubble.clock==30)
bubble.phase='clear';bubble.timer=0;require('games.coop.bubbles').step(bubble,{},.01)
assert(bubble.phase=='won');defaults(bubbles)
local pinpals=games[8];pinpals.setting('speed',60)
local board=pinpals.new(roster());local before=board.match.state.tick
pinpals.update(board,1/30,{{},{}})
local slowTicks=board.match.state.tick-before;pinpals.dispose(board)
pinpals.setting('speed',125);board=pinpals.new(roster());before=board.match.state.tick
pinpals.update(board,1/30,{{},{}});assert(board.match.state.tick-before>slowTicks);pinpals.dispose(board);defaults(pinpals)
print('PASS settings affect gameplay and respect round boundaries for all eight shared games')




local output=os.getenv('GNLOVE_SETTINGS_OUTPUT')
if output then
 local result={};for _,game in ipairs(games) do result[game.id]=game.settings end
 local file=assert(io.open(output,'w'));file:write(require('vendor.json').encode(result));file:close()
end
