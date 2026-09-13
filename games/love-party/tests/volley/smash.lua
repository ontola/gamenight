return function()
  local S=require("games.volley.sim")
  local function setup()
    local g=S.new({seats={{slot=1,name="P1"}}}); g.phase="play"
    g.ball.x,g.ball.y=g.players[1].x,g.players[1].y-65
    return g,g.players[1]
  end
  local function smashed(g)
    for _,e in ipairs(g.events) do if e.kind=="smash" then return true end end
    return false
  end
  for i=0,7 do
    local g=setup(); local angle=i*math.pi/4
    local x,y=math.cos(angle),math.sin(angle)
    S.step(g,{[1]={smash=true,aimX=x,aimY=y}},1/120)
    assert(smashed(g),"smash should connect in all eight aim directions")
    assert(math.abs(g.ball.vx-x*980)<.1 and math.abs(g.ball.vy-y*980)<.1,"normalized aim controls shot velocity")
  end
  local g,p=setup()
  p.grounded=false; p.y=400; p.vy=-200; g.ball.y=335
  S.step(g,{[1]={smash=true,aimX=1,aimY=.4}},1/120)
  assert(smashed(g) and math.sqrt(g.ball.vx^2+g.ball.vy^2)>1070,"airborne smash gains power")
  g,p=setup(); g.ball.x=p.x+130; g.ball.y=p.y-10
  S.step(g,{[1]={smash=true}},1/120)
  assert(not smashed(g) and p.smashCooldown>0,"miss consumes cooldown without remote hit")
  g,p=setup(); g.ball.x=p.x+89; g.ball.y=p.y-10; g.ball.vx=-250
  for i=1,8 do S.step(g,{[1]={smash=i==1,aimX=1,aimY=-1}},1/120) end
  assert(smashed(g),"early press remains active briefly")
  g,p=setup()
  S.step(g,{[1]={smash=true,aimX=1,aimY=-1}},1/120)
  for _=1,130 do
    g.ball.x,g.ball.y,g.ball.vx,g.ball.vy=p.x,p.y-65,0,0
    g.events={}; S.step(g,{[1]={smash=true}},1/120)
    assert(not smashed(g),"held button must not auto-repeat")
  end
  S.step(g,{[1]={smash=false}},1/120)
  S.step(g,{[1]={smash=true}},1/120); assert(smashed(g),"release re-arms smash")
  g,p=setup(); p.x=599; g.ball.x,g.ball.y=669,p.y
  S.step(g,{[1]={smash=true,aimX=1}},1/120)
  assert(not smashed(g),"cannot smash through net")
  g,p=setup(); g.arena="scaffolding"; p.x,p.y=220,585; g.ball.x,g.ball.y=220,518
  S.step(g,{[1]={smash=true,aimY=-1}},1/120)
  assert(not smashed(g),"cannot smash through platform")
  g,p=setup(); g.ball.ghost=.5
  S.step(g,{[1]={smash=true}},1/120); assert(not smashed(g),"reforming ball is not hittable")
  g,p=setup(); S.serve(g,1)
  assert(p.swing==0 and p.smashCooldown==0 and not p.smashWas,"serve clears swing state")
end
