local S=require("games.volley.sim")
local R=require("games.volley.render")
local A=require("games.volley.audio")
local Input=require("shared.input")
local M={id="volley-trouble",title="Volley Trouble",tagline="Good friends. Terrible teamwork.",
 controls="A jump / B or RB smash / right stick aim",duration=math.huge,coop=true}
local settings={arena="beach",bomb=false,target=7,variety=true}
M.settings={
 {key="arena",label="Court",kind="choice",default="beach",options={"beach","scaffolding","elevator","lava"}},
 {key="bomb",label="Exploding ball",kind="toggle",default=false},
 {key="variety",label="Rotating round rules",kind="toggle",default=true},
 {key="target",label="Points to win",kind="number",default=7,min=1,max=21}}
function M.setting(key,value)
 if key=="arena" then for _,a in ipairs(S.arenas) do if a.id==value then settings.arena=value end end
 elseif (key=="bomb" or key=="variety") and type(value)=="boolean" then settings[key]=value
 elseif key=="target" and type(value)=="number" then settings.target=S.clamp(math.floor(value),1,21) end
end
function M.roster(players)
 table.sort(players,function(a,b) return a.slot<b.slot end)
 for i,p in ipairs(players) do p.team=(i-1)%2+1 end
 return players
end
function M.new(players)
 local s=S.new({seats=M.roster(players),arena=settings.arena,bomb=settings.bomb,target=settings.target,variety=settings.variety})
 for i,p in ipairs(s.players) do
  local identity=players[i]
  p.id,p.controller,p.color,p.skin_color=identity.id,identity.controller,identity.color,identity.skin_color
  p.score=0
 end
 s.presentation={game=s,fx={particles={},rings={},trail={}},toastLife=0,screen="play"}
 return s
end
function M.load() A.load() end
function M.mute() if love.audio then A.stop() end end
function M.input(slot)
 local raw=Input.sample(slot)
 local pad=Input.pads[slot]
 local k=Input.keys[slot]
 local jump=love.keyboard and love.keyboard.isDown(k[3]) or false
 local smash=love.keyboard and love.keyboard.isDown(k[5]) or false
 if pad and pad:isConnected() then
  jump=jump or pad:isGamepadDown("a")
  smash=smash or pad:isGamepadDown("b","rightshoulder") or pad:getGamepadAxis("triggerright")>.35
 end
 local ax,ay=raw.aimX,raw.aimY
 if smash and ax==0 and ay==0 then ax,ay=raw.x,raw.y end
 return {move=raw.x,jump=jump,smash=smash,aimX=ax,aimY=ay}
end
function M.bot(s,p) return S.bot(s,p) end
local function effects(app,dt)
  local fx=app.fx
  for i=#fx.particles,1,-1 do
    local p=fx.particles[i]; p.life=p.life-dt; p.x=p.x+p.vx*dt; p.y=p.y+p.vy*dt; p.vy=p.vy+340*dt
    if p.life<=0 then table.remove(fx.particles,i) end
  end
  for i=#fx.rings,1,-1 do fx.rings[i].life=fx.rings[i].life-dt; if fx.rings[i].life<=0 then table.remove(fx.rings,i) end end
  for i=#fx.trail,1,-1 do fx.trail[i].life=fx.trail[i].life-dt*3; if fx.trail[i].life<=0 then table.remove(fx.trail,i) end end
  if app.game.phase=="play" then
    for _,b in ipairs(app.game.balls or {app.game.ball}) do
      if b.ghost<=0 then fx.trail[#fx.trail+1]={x=b.x,y=b.y,r=b.r*.65,life=1} end
    end
  end
  for _,e in ipairs(app.game.events) do
    A.play(e.kind)
    local big=e.kind=="explode" or e.kind=="point" or e.kind=="win" or e.kind=="smash"
    local count=big and 38 or 10
    for _=1,count do
      local a=love.math.random()*math.pi*2; local speed=love.math.random(60,big and 390 or 180)
      local life=love.math.random()*.35+.25
      fx.particles[#fx.particles+1]={x=e.x,y=e.y,vx=math.cos(a)*speed,vy=math.sin(a)*speed-60,life=life,max=life,r=love.math.random(2,5),team=e.extra}
    end
    fx.rings[#fx.rings+1]={x=e.x,y=e.y,life=big and .55 or .25,max=big and .55 or .25,radius=e.kind=="explode" and 245 or 65,kind=e.kind}
    if e.kind=="spike" then app.toast="POWER HIT!"; app.toastLife=.7 end
    if e.kind=="explode" then app.toast="BOOM!  THE BALL RETURNS..."; app.toastLife=.8 end
  end
  app.game.events={}
end

function M.update(s,dt,inputs)
 local bySlot={}
 for i,p in ipairs(s.players) do bySlot[p.slot]=inputs[i] end
 S.step(s,bySlot,dt)
 effects(s.presentation,dt)
 s.presentation.toastLife=math.max(0,s.presentation.toastLife-dt)
 s.over=s.phase=="finished"
end
function M.finish(s) s.phase="finished"; s.winner=s.winner or (s.score[1]>=s.score[2] and 1 or 2) end
function M.render(s)
 local w,h=love.graphics.getDimensions()
 local scale=math.min(w/1216,h/584)
 love.graphics.clear(.10,.18,.24)
 love.graphics.push(); love.graphics.translate((w-1280*scale)/2,h-(S.floor+20)*scale); love.graphics.scale(scale)
 R.scene(s,s.presentation.fx); R.hud(s,s.presentation)
 if s.phase=="finished" then R.overlay(s.presentation) end
 love.graphics.pop()
end
return M
