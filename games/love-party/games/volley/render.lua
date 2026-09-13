local S = require("games.volley.sim")
local Avatar = require("games.volley.avatar")
local R = {}
local ink={.055,.085,.13}
local cream={.96,.95,.85}
local muted={.49,.61,.66}
local coral={1,.40,.31}
local mint={.36,.92,.72}
local gold={1,.8,.35}
local colors={coral,mint,{1,.68,.39},{.42,.76,1}}
local fonts={}
local function color(c,a) love.graphics.setColor(c[1],c[2],c[3],a or 1) end
local function box(c,x,y,w,h,r,a) color(c,a); love.graphics.rectangle("fill",x,y,w,h,r or 0) end
local function text(s,x,y,size,c,w,align)
  if not fonts[size] then fonts[size]=love.graphics.newFont(size) end
  love.graphics.setFont(fonts[size]); color(c or cream)
  if w then love.graphics.printf(s,x,y,w,align or "left") else love.graphics.print(s,x,y) end
end
R.text=text
local function line(c,x1,y1,x2,y2,width,a)
  color(c,a); love.graphics.setLineWidth(width or 1); love.graphics.line(x1,y1,x2,y2)
end
local function circle(c,x,y,r,a) color(c,a); love.graphics.circle("fill",x,y,r) end
local function arenaInfo(id) for _,a in ipairs(S.arenas) do if a.id==id then return a end end end
function R.background(g)
  box(ink,0,0,1280,800)
  -- The court fills the view; no surrounding application panels.
  local lava=S.lava(g)
  -- A layered dusk skyline, all drawn locally: no asset downloads or shaders.
  for i=0,30 do
    local t=i/30
    box(lava and {.19+t*.045,.12+t*.025,.17+t*.01} or {.10+t*.025,.18+t*.07,.24+t*.07},0,i*27,1280,28)
  end
  circle(lava and coral or gold,975,319,83,.88)
  for i=1,6 do box(lava and {.22,.135,.18} or {.12,.23,.30},880,335+i*12,200,3+i) end
  color(lava and {.12,.10,.16} or {.075,.17,.23})
  love.graphics.polygon("fill",32,516,135,404,240,481,375,380,500,510,645,458,770,510,910,404,1090,492,1248,410,1248,685,32,685)
  box(lava and {.16,.11,.16} or {.07,.20,.25},32,563,1216,121)
  for i=1,9 do
    local y=576+i*11
    line(lava and coral or mint,50+math.sin(i*2+g.time*.4)*25,y,1230,y,1,.045)
  end
  -- Boundary rails and team-owned scoring floors.
  box(coral,32,684,600,5); box(mint,648,684,600,5)
  box({.10,.15,.19},32,689,1216,26,0)
  for x=45,1235,25 do line(muted,x,705,x+9,696,1,.18) end
  if lava then
    for _,patch in ipairs(S.lavaPatches) do
      local x=patch.x
      box({.3,.11,.13},x,680,patch.w,25)
      for j=0,math.ceil(patch.w/10)-1 do
        local h=7+math.sin(g.time*6+j*2)*5
        box(j%2==0 and gold or coral,x+j*10,680-h,math.min(10,patch.w-j*10),h+8,3)
      end
    end
  end
  for _,p in ipairs(S.platforms(g)) do
    if g.arena=="elevator" then
      line(muted,p.x+p.w/2,225,p.x+p.w/2,675,2,.22)
      for y=235,670,22 do line(muted,p.x+p.w/2-6,y,p.x+p.w/2+6,y,2,.18) end
    else
      line(muted,p.x+15,p.y+18,p.x+15,678,2,.18)
      line(muted,p.x+p.w-15,p.y+18,p.x+p.w-15,678,2,.18)
    end
    box({.09,.12,.17},p.x-3,p.y+3,p.w+6,p.h+5,4)
    box(gold,p.x,p.y,p.w,p.h,4)
    for x=p.x+10,p.x+p.w-10,20 do line(ink,x,p.y+5,x+8,p.y+12,2,.5) end
  end
  -- See-through net, with a bright, readable collision rail.
  for y=S.net+12,680,14 do line(cream,634,y,646,y,1,.3) end
  line(cream,640,S.net+5,640,684,2,.38)
  box(cream,632,S.net,16,7,3)
  circle(gold,640,S.net,6)
end
local function player(p,g)
  local c=colors[p.team+(p.slot>=3 and 2 or 0)] or cream
  if p.out>0 then
    circle(c,p.x,635,26,.15)
    return
  end
  local elevation=math.max(0,S.floor-p.y-S.radius)
  color(ink,.3); love.graphics.ellipse("fill",p.x,S.floor-3,math.max(10,27-elevation*.035),5)
  local stretch=S.clamp(-p.vy/2600,-.13,.17)
  love.graphics.push(); love.graphics.translate(p.x,p.y); love.graphics.scale(1-stretch,1+stretch)
  circle(ink,0,3,32); circle(c,0,0,29)
  circle(cream,-9,-10,7,.20)
  if p.portrait==nil then p.portrait=Avatar.image(p.avatar) or false end
  if p.portrait then
    local w,h=p.portrait:getDimensions()
    local scale=48/math.max(w,h)
    color(cream); love.graphics.setColor(1,1,1,1)
    love.graphics.draw(p.portrait,-w*scale/2,-h*scale/2,0,scale,scale)
  else
    -- Players without a drawing keep a readable default face.
    box(ink,-26,-14,52,8,3,.8)
    local look=S.clamp((g.ball.x-p.x)/200,-1,1)*3
    circle(cream,-9,0,7); circle(cream,10,0,7)
    circle(ink,-9+look,1,3); circle(ink,10+look,1,3)
    line(ink,-4,15,5,15,3)
  end
  box(ink,-20,24,14,8,4); box(ink,7,24,14,8,4)
  love.graphics.pop()
  if (p.smashCooldown or 0)>0 then
    color(c,.55); love.graphics.setLineWidth(2)
    love.graphics.arc("line","open",p.x,p.y,35,-math.pi/2,-math.pi/2+math.max(.01,1-p.smashCooldown/.85)*math.pi*2)
  end
  if (p.aimDisplay or 0)>0 then
    local ax,ay=p.aimX,p.aimY
    local reach=(p.swing or 0)>0 and 90 or 73
    local x,y=p.x+ax*reach,p.y+ay*reach
    line(gold,p.x+ax*39,p.y+ay*39,x,y,3,.85)
    line(gold,x,y,x-ax*11-ay*7,y-ay*11+ax*7,3,.85)
    line(gold,x,y,x-ax*11+ay*7,y-ay*11-ax*7,3,.85)
  end
end
function R.ball(g,b)
  b=b or g.ball
  if b.ghost>0 then
    color(gold,.5); love.graphics.setLineWidth(2)
    love.graphics.circle("line",b.x,220,25+math.sin(g.time*15)*4)
    return
  end
  if g.bomb and b.fuse<2 then circle(coral,b.x,b.y,30+math.sin(g.time*25)*4,.14) end
  circle(ink,b.x+2,b.y+4,b.r+2,.45)
  love.graphics.push(); love.graphics.translate(b.x,b.y); love.graphics.rotate(b.angle)
  circle(g.bomb and {.18,.21,.25} or cream,0,0,b.r)
  color(g.bomb and coral or coral); love.graphics.setLineWidth(4)
  love.graphics.arc("line","open",0,0,13,-1.3,1.3)
  line(g.bomb and gold or {.18,.50,.52},-12,-14,7,16,4)
  circle(cream,-7,-9,4,.6)
  love.graphics.pop()
  if g.bomb then
    color(b.fuse<2 and coral or gold); love.graphics.setLineWidth(3)
    love.graphics.arc("line","open",b.x,b.y,27,-math.pi/2,-math.pi/2+math.max(.01,b.fuse/6.5)*math.pi*2)
  end
end
function R.scene(g,fx)
  R.background(g)
  for _,v in ipairs(fx.trail or {}) do circle(g.bomb and coral or gold,v.x,v.y,v.r,v.life*.3) end
  for _,p in ipairs(g.players) do player(p,g) end
  for _,b in ipairs(g.balls or {g.ball}) do R.ball(g,b) end
  for _,p in ipairs(fx.particles or {}) do circle(p.team==1 and coral or p.team==2 and mint or gold,p.x,p.y,p.r,p.life/p.max) end
  for _,r in ipairs(fx.rings or {}) do
    color(r.kind=="explode" and coral or gold,r.life/r.max)
    love.graphics.setLineWidth(r.kind=="explode" and 5 or 2)
    love.graphics.circle("line",r.x,r.y,r.radius*(1-r.life/r.max)+10)
  end
end
function R.hud(g,app)
  -- Only match state belongs over the court: score and a brief serve countdown.
  text(tostring(g.score[1]),548,163,32,coral,72,"center")
  text(tostring(g.score[2]),660,163,32,mint,72,"center")
  if g.phase=="serve" then
    text(S.ruleNames[g.rule or "classic"],360,205,22,gold,560,"center")
    text(S.ruleHints[g.rule or "classic"],340,236,13,cream,600,"center")
    text(tostring(math.ceil(g.timer)),g.ball.x-30,246,26,
      g.serveTeam==1 and coral or mint,60,"center")
  end
end
function R.menu(app)
  box(ink,0,0,1280,800,0,.86)
  text("G A M E N I G H T   O R I G I N A L S",76,56,12,mint)
  text("VOLLEY",70,91,86,cream)
  text("TROUBLE",70,180,86,coral)
  text("Good friends. Terrible teamwork.",76,290,21,cream)
  text("Jump into the ball. Get it over the net.\nMake it land on their floor.",76,343,18,muted)
  box({.13,.19,.23},76,448,490,157,16)
  text("SMALL CONTROLS. BIG CHAOS.",98,469,12,gold)
  text("MOVE  Left stick      JUMP  A\nAIM     Right stick    SMASH  RT / RB / B\n\nKeyboard: A D + W jump + SPACE smash",98,497,16,cream)
  text("P2  ARROWS     P3  J / L / I     P4  NUMPAD",76,627,11,muted)
  text("UP / DOWN  SELECT     LEFT / RIGHT  CHANGE",680,90,11,muted)
  local arena=S.arenas[app.selection.arena]
  local modes={"PRACTICE  /  YOU + CPU","1 vs 1  /  TWO PLAYERS","2 vs 2  /  FOUR PLAYERS"}
  local rows={{"01   THE COURT",arena.name},{"02   THE CREW",modes[app.selection.mode]},
    {"03   THE BALL",app.selection.bomb and "HOT POTATO" or "CLASSIC VOLLEY"},
    {"04   ROUND RULES",app.selection.variety and "PARTY MIX" or "CLASSIC ONLY"},{"05   LET'S PLAY","HIT THE COURT"}}
  for i,row in ipairs(rows) do
    local y=118+(i-1)*98
    local selected=app.menuRow==i
    box(selected and {.17,.25,.28} or {.095,.14,.18},668,y,530,88,13)
    if selected then box(mint,668,y+17,4,66,2) end
    text(row[1],692,y+17,11,selected and mint or muted)
    text(row[2],692,y+43,22,i==5 and gold or cream)
    text(selected and (i==5 and "GO >" or "<  >") or "",1114,y+45,16,mint,62,"right")
  end
  text(arena.subtitle,680,618,14,muted,510)
  if app.selection.bomb then text("A timed blast shoves everyone nearby. The ball reforms!",680,655,13,gold,510) end
  text("ENTER / A  PLAY",680,724,17,mint)
  local pads=0; for i=1,4 do if app.pads[i] and app.pads[i]:isConnected() then pads=pads+1 end end
  text(pads.." CONTROLLER"..(pads==1 and "" or "S").." CONNECTED  /  KEYBOARD ALWAYS AVAILABLE",680,691,11,muted)
  text("F11 FULLSCREEN     M SOUND",76,748,11,muted)
end
function R.overlay(app)
  local g=app.game
  box(ink,0,0,1280,800,0,.45)
  if g.phase=="finished" then
    text(g.score[1].."  :  "..g.score[2],400,350,64,
      g.winner==1 and coral or mint,480,"center")
  else
    box(cream,616,366,16,56,3)
    box(cream,648,366,16,56,3)
  end
end
return R
