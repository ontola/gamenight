-- Pure Lua simulation. Fixed ticks, no rendering, input devices or random state.
local S = { W = 1280, H = 800, floor = 684, net = 468, radius = 29 }
S.moveSpeed=650
S.lavaPatches={{x=243,w=100},{x=937,w=100}}
S.rules={"classic","double","moon","lava","speed"}
S.ruleNames={classic="CLASSIC VOLLEY",double="DOUBLE TROUBLE",moon="MOON BALL",lava="LAVA SAVES",speed="FAST & SMALL"}
S.ruleHints={classic="Get it over the net.",double="Two balls. First floor hit ends the rally.",moon="Low gravity for players and balls.",lava="Glowing floor saves the ball. Players still burn!",speed="A smaller ball with faster hits."}
function S.lava(g) return g.arena=="lava" or g.rule=="lava" end
S.arenas = {
  { id = "beach", name = "SUNSET BEACH", subtitle = "Just you, the net, and questionable teamwork.", tag = "THE CLASSIC" },
  { id = "scaffolding", name = "HIGH TIDE", subtitle = "Climb the platforms. Own the air.", tag = "PLATFORM PLAY" },
  { id = "elevator", name = "UP & OVER", subtitle = "Moving platforms. Moving targets.", tag = "MOVING FLOORS" },
  { id = "lava", name = "HOT FOOT", subtitle = "Mind the glowing pits. Your teammate has you. Probably.", tag = "DANGER COURT" },
}
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
S.clamp = clamp
local function event(g, kind, x, y, extra)
  g.events[#g.events + 1] = { kind = kind, x = x, y = y, extra = extra }
end
function S.platforms(g)
  local a = g.arena
  if a == "scaffolding" then
    return { {x=158,y=552,w=158,h=16}, {x=440,y=414,w=120,h=16},
      {x=964,y=552,w=158,h=16}, {x=720,y=414,w=120,h=16} }
  elseif a == "elevator" then
    local offset = math.sin(g.time * .9) * 84
    return { {x=270,y=520+offset,w=180,h=18}, {x=830,y=520-offset,w=180,h=18} }
  elseif a == "lava" then
    return { {x=218,y=561,w=150,h=18}, {x=912,y=561,w=150,h=18} }
  end
  return {}
end
function S.hazard(x)
  for _,patch in ipairs(S.lavaPatches) do if x>patch.x and x<patch.x+patch.w then return true end end
  return false
end
local function home(p)
  return p.team == 1 and (p.slot < 3 and 310 or 160) or (p.slot < 3 and 970 or 1120)
end
local function spawn(g,p)
  if S.lava(g) then return p.team==1 and (p.slot<3 and 440 or 130) or (p.slot<3 and 840 or 1150) end
  return home(p)
end
function S.serve(g, team)
  g.round=(g.round or 0)+1
  g.rule=g.fixedRule or (g.variety and S.rules[(g.round-1)%#S.rules+1] or "classic")
  g.gravity=g.rule=="moon" and .55 or 1
  g.botForecast=nil
  g.serveTeam = team
  g.ball = {x=team == 1 and 320 or 960,y=250,vx=0,vy=0,r=20,fuse=6.5,ghost=0,touches=0,angle=0,ignoreTime=0}
  g.balls={g.ball}
  if g.rule=="speed" then g.ball.r=14 end
  if g.rule=="double" then
    g.balls[2]={x=team==1 and 960 or 320,y=310,vx=0,vy=0,r=20,fuse=7.5,ghost=0,touches=0,angle=0,ignoreTime=0}
  end
  g.phase, g.timer = "serve", (g.variety or g.fixedRule) and 2 or 1.25
  for _, p in ipairs(g.players) do
    p.x,p.y,p.vx,p.vy,p.out,p.grounded,p.cooldown = spawn(g,p),S.floor-S.radius,0,0,0,true,0
    p.jumpWas,p.coyote,p.buffer,p.support = false,.1,0,nil
    p.botJumpUntil,p.botNextJump=0,0
    p.botInput,p.botThinkAt=nil,0
    p.defeated=false
    p.swing,p.smashCooldown,p.smashWas,p.aimDisplay=0,0,false,0
    p.aimX,p.aimY=p.team==1 and .79 or -.79,-.61
  end
end
function S.new(opts)
  opts = opts or {}
  local g = {arena=opts.arena or "beach", bomb=opts.bomb or false, target=opts.target or 10,
    score={0,0}, players={}, time=0, events={}, phase="serve", timer=0,variety=opts.variety or false,fixedRule=opts.rule}
  local seats = opts.seats or {{slot=1,name="YOU",bot=false},{slot=2,name="RIVAL",bot=true}}
  for i,s in ipairs(seats) do
    local slot = s.slot or i
    g.players[#g.players+1] = {slot=slot,team=s.team or ((slot-1)%2+1),name=s.name or ("P"..slot),avatar=s.avatar,bot=s.bot or false}
  end
  S.serve(g,1)
  return g
end
local function forecast(g)
  local cached=g.botForecast
  if cached and cached.ball==g.ball and g.time-cached.time<.10 and cached.touches==g.ball.touches then return cached.path end
  local ball={}; for k,v in pairs(g.ball) do ball[k]=v end
  -- Forecast with the actual ball rules: walls, net, moving platforms and bombs.
  -- No players in the shadow world, so this cannot recursively invoke the AI.
  local shadow={ball=ball,players={},arena=g.arena,bomb=g.bomb,time=g.time,phase=g.phase,
    timer=g.timer,serveTeam=g.serveTeam,score={0,0},target=1,events={},gravity=g.gravity,rule=g.rule}
  local path={}
  for i=1,144 do
    S.step(shadow,{},1/60)
    if shadow.phase=="point" or shadow.phase=="finished" then break end
    if ball.ghost<=0 then path[#path+1]={x=ball.x,y=ball.y,vy=ball.vy,t=i/60} end
    shadow.events={}
  end
  g.botForecast={ball=g.ball,time=g.time,touches=g.ball.touches,path=path}
  return path
end
function S.bot(g,p)
  if p.out>0 or p.defeated then return {} end
  if p.botInput and g.time<(p.botThinkAt or 0) then return p.botInput end
  p.botThinkAt=g.time+.18
  local direction=p.team==1 and 1 or -1
  local low,high=p.team==1 and 42 or 681,p.team==1 and 599 or 1238
  local path=forecast(g)
  local target=spawn(g,p)
  local contact, jumpContact
  for _,b in ipairs(path) do
    if b.x>=low-20 and b.x<=high+20 then
      local aim=clamp(b.x-direction*25,low,high)
      local reachable=math.abs(aim-p.x)<S.moveSpeed*math.max(0,b.t-.05)+26
      local bodyY=p.grounded and p.y or math.min(S.floor-S.radius,p.y+p.vy*b.t+790*(g.gravity or 1)*b.t*b.t)
      if reachable and b.vy>0 and b.y>=bodyY-58 and b.y<bodyY+5 then
        contact={x=aim,t=b.t}; break
      end
    end
  end
  if contact then target=contact.x else
    -- Track an approaching shot before it crosses the net, even if currently out of reach.
    for _,b in ipairs(path) do
      if b.x>=low and b.x<=high and b.vy>0 and b.y>500 then target=b.x-direction*25; break end
    end
  end
  local chaser=p
  -- One teammate takes the ball; the other covers the back court instead of piling on.
  for _,mate in ipairs(g.players) do
    if mate~=p and mate.team==p.team and mate.out<=0 then
      local mine=math.abs(target-p.x); local theirs=math.abs(target-mate.x)
      if theirs<mine-25 or (math.abs(theirs-mine)<=25 and mate.slot<p.slot) then chaser=mate end
    end
  end
  local jump=false
  if chaser==p then
    if p.grounded and g.time>=(p.botNextJump or 0) then
      for _,b in ipairs(path) do
        if b.t>=.10 and b.t<=.42 and b.x>=low-20 and b.x<=high+20 then
          local jumpY=p.y-690*b.t+790*(g.gravity or 1)*b.t*b.t
          local aim=clamp(b.x-direction*25,low,high)
          if math.abs(aim-p.x)<S.moveSpeed*math.max(0,b.t-.04)+20 and math.abs(b.y-(jumpY-38))<25 then
            jumpContact=aim; break
          end
        end
      end
    end
    if jumpContact then target=jumpContact; jump=true end
  else target=p.team==1 and 190 or 1090 end
  target=clamp(target,low,high)
  if S.lava(g) then
    -- Approach the pit lip before jumping; do not jump at distant lava or park in it.
    local move=target>p.x and 1 or -1
    if p.grounded and S.hazard(p.x+move*48) and math.abs(target-p.x)>35 then jump=true end
    if S.hazard(target) and chaser~=p then target=p.team==1 and 145 or 1135 end
  end
  if jump and p.grounded and g.time>=(p.botNextJump or 0) then
    p.botJumpUntil=g.time+.42; p.botNextJump=g.time+.65
  end
  -- Braking uses velocity, avoiding the old left/right oscillation under a falling ball.
  target=clamp(target+math.sin(g.time*1.7+p.slot*2)*24,low,high)
  local error=target-p.x
  local move=clamp((error*7-p.vx*.7)/260,-1,1)
  if math.abs(error)<5 and math.abs(p.vx)<20 then move=0 end
  local b=g.ball
  local near=(b.x-p.x)^2+(b.y-p.y)^2<72^2
  p.botInput={move=move*.88,jump=g.time<(p.botJumpUntil or 0),
    smash=chaser==p and near and (p.smashCooldown or 0)<=0 and g.phase=="play",
    aimX=direction,aimY=b.y<S.net-65 and .35 or -.95}
  return p.botInput
end
local function playerStep(g,p,input,dt,platforms,oldPlatforms)
  p.cooldown = math.max(0,p.cooldown-dt)
  p.swing=math.max(0,(p.swing or 0)-dt)
  p.smashCooldown=math.max(0,(p.smashCooldown or 0)-dt)
  p.aimDisplay=math.max(0,(p.aimDisplay or 0)-dt)
  if p.out>0 then
    p.out=p.out-dt
    if p.out<=0 then p.x,p.y,p.vx,p.vy=spawn(g,p),430,0,0; event(g,"respawn",p.x,p.y,p.team) end
    return
  end
  input=input or {}
  local move=clamp(input.move or 0,-1,1)
  local jump=input.jump or false
  local ax,ay=input.aimX or 0,input.aimY or 0
  local length=math.sqrt(ax*ax+ay*ay)
  if length>.25 then
    p.aimX,p.aimY=ax/length,ay/length
    p.aimDisplay=.15
  elseif p.swing<=0 then
    ax=p.team==1 and 1 or -1
    ay=g.ball.y<S.net-65 and .32 or -.8
    length=math.sqrt(ax*ax+ay*ay); p.aimX,p.aimY=ax/length,ay/length
  end
  if input.smash and not p.smashWas and p.smashCooldown<=0 and g.phase=="play" then
    p.swing=.16; p.smashCooldown=.85; p.aimDisplay=.22
    event(g,"swing",p.x,p.y,p.team)
  end
  p.smashWas=input.smash or false
  if p.support and platforms[p.support] and oldPlatforms[p.support] then
    p.y = p.y + platforms[p.support].y-oldPlatforms[p.support].y
  end
  p.coyote = p.grounded and .10 or math.max(0,p.coyote-dt)
  p.buffer = jump and not p.jumpWas and .12 or math.max(0,p.buffer-dt)
  if p.buffer>0 and p.coyote>0 then
    p.vy=-690; p.grounded=false; p.support=nil; p.coyote=0; p.buffer=0
    event(g,"jump",p.x,p.y+S.radius,p.team)
  end
  if not jump and p.jumpWas and p.vy < -280 then p.vy=-280 end
  p.jumpWas=jump
  local desired = move*S.moveSpeed
  p.vx = p.vx + clamp(desired-p.vx,-5200*dt,5200*dt)
  local oldBottom=p.y+S.radius
  p.x=p.x+p.vx*dt
  p.vy=p.vy+1580*(g.gravity or 1)*dt
  p.y=p.y+p.vy*dt
  if p.y<150+S.radius then p.y=150+S.radius; p.vy=math.max(0,p.vy) end
  p.x=clamp(p.x,p.team==1 and 42 or 640+12+S.radius,p.team==1 and 640-12-S.radius or 1238)
  p.grounded,p.support=false,nil
  -- One-way player platforms: jump through, land on top. Ball sees solid geometry.
  for i,r in ipairs(platforms) do
    local old=oldPlatforms[i] or r
    if p.vy>=0 and p.x+20>r.x and p.x-20<r.x+r.w and oldBottom<=old.y+3 and p.y+S.radius>=r.y then
      p.y,p.vy,p.grounded,p.support=r.y-S.radius,0,true,i
    end
  end
  if p.y+S.radius>=S.floor then
    if S.lava(g) and S.hazard(p.x) then
      p.out=1.35; event(g,"lava",p.x,S.floor,p.team)
    else p.y,p.vy,p.grounded=S.floor-S.radius,0,true end
  end
end
local function rectBounce(b,r)
  local cx,cy=clamp(b.x,r.x,r.x+r.w),clamp(b.y,r.y,r.y+r.h)
  local dx,dy=b.x-cx,b.y-cy
  local d2=dx*dx+dy*dy
  if d2>=b.r*b.r then return end
  local nx,ny,depth
  if d2>.0001 then
    local d=math.sqrt(d2); nx,ny,depth=dx/d,dy/d,b.r-d
  else
    local distances={b.x-r.x,r.x+r.w-b.x,b.y-r.y,r.y+r.h-b.y}
    local k=1; for i=2,4 do if distances[i]<distances[k] then k=i end end
    nx=(k==1 and -1 or k==2 and 1 or 0); ny=(k==3 and -1 or k==4 and 1 or 0)
    depth=b.r+distances[k]
  end
  b.x,b.y=b.x+nx*(depth+.1),b.y+ny*(depth+.1)
  local dot=b.vx*nx+b.vy*ny
  if dot<0 then
    b.vx,b.vy=b.vx-1.85*dot*nx,b.vy-1.85*dot*ny
    -- Platforms must never become a resting place that stalls a rally.
    if ny<-.7 then
      b.vy=math.min(b.vy,-330)
      if math.abs(b.vx)<100 then b.vx=b.x<640 and 180 or -180 end
    end
  end
end
local function point(g,team,b)
  g.score[team]=g.score[team]+1
  event(g,"point",b.x,S.floor,team)
  g.phase,g.timer,g.pointTeam="point",1.65,team
  for _,p in ipairs(g.players) do
    if p.team~=team then p.defeated=true; event(g,"defeat",p.x,p.y,p.team) end
  end
  if g.score[team]>=g.target then g.winner=team; event(g,"win",640,320,team) end
end
local function smashReach(g,p,b,platforms)
  local obstacles={{x=632,y=S.net,w=16,h=S.floor-S.net}}
  for _,r in ipairs(platforms) do obstacles[#obstacles+1]=r end
  -- A swing cannot reach through the net or a solid platform.
  for i=1,12 do
    local x,y=p.x+(b.x-p.x)*i/12,p.y+(b.y-p.y)*i/12
    for _,r in ipairs(obstacles) do
      if x>=r.x and x<=r.x+r.w and y>=r.y and y<=r.y+r.h then return false end
    end
  end
  return true
end
local function stepBall(g,b,dt,platforms)
  b.ignoreTime=math.max(0,(b.ignoreTime or 0)-dt)
  if b.ghost>0 then
    b.ghost=b.ghost-dt
    if b.ghost<=0 then b.y=220; b.vx=0; b.vy=70; b.fuse=6.5; event(g,"reform",b.x,b.y) end
    return
  end
  if g.bomb then
    b.fuse=b.fuse-dt
    if b.fuse<=0 then
      event(g,"explode",b.x,b.y)
      for _,p in ipairs(g.players) do
        local dx,dy=p.x-b.x,p.y-b.y
        local d=math.sqrt(dx*dx+dy*dy)
        if d<245 and p.out<=0 then
          p.vx=(dx>=0 and 1 or -1)*(1-d/300)*1050; p.vy=-640
          p.grounded=false; p.support=nil
        end
      end
      b.ghost=.8; b.x=clamp(b.x,80,1200)
      return
    end
  end
  -- Microsteps keep even a maximum-speed spike from tunnelling through a platform.
  local n=math.max(1,math.ceil(math.sqrt(b.vx*b.vx+b.vy*b.vy)*dt/8))
  local h=dt/n
  for _=1,n do
    b.vy=b.vy+790*(g.gravity or 1)*h
    b.x,b.y=b.x+b.vx*h,b.y+b.vy*h
    b.angle=b.angle+b.vx*h*.008
    if b.x<32+b.r then b.x=32+b.r; b.vx=math.abs(b.vx)*.88 end
    if b.x>1248-b.r then b.x=1248-b.r; b.vx=-math.abs(b.vx)*.88 end
    if b.y<150+b.r then b.y=150+b.r; b.vy=math.abs(b.vy)*.8 end
    rectBounce(b,{x=632,y=S.net,w=16,h=S.floor-S.net})
    for _,r in ipairs(platforms) do rectBounce(b,r) end
    for _,p in ipairs(g.players) do
      if p.out<=0 and not (b.ignoreSlot==p.slot and (b.ignoreTime or 0)>0) then
        local dx,dy=b.x-p.x,b.y-p.y
        local dist=math.sqrt(dx*dx+dy*dy)
        if (p.swing or 0)>0 and dist<80 and smashReach(g,p,b,platforms) then
          local power=(p.grounded and 980 or 1080)+(dist<53 and 70 or 0)
          if g.rule=="speed" then power=power*1.15 end
          b.vx,b.vy=p.aimX*power,p.aimY*power
          b.touches=b.touches+1
          b.ignoreSlot,b.ignoreTime=p.slot,.12
          p.swing=0; p.cooldown=.18
          event(g,"smash",b.x,b.y,p.team)
        elseif dist<b.r+S.radius then
          local nx,ny=dx/math.max(dist,.001),dy/math.max(dist,.001)
          if dist<.001 then nx,ny=0,-1 end
          b.x,b.y=p.x+nx*(b.r+S.radius+.2),p.y+ny*(b.r+S.radius+.2)
          if p.cooldown<=0 then
            local rising=p.vy < -90
            local direction=p.team==1 and 1 or -1
            b.touches=b.touches+1
            local power=1+(g.bomb and math.min(b.touches*.045,.38) or 0)
            if g.rule=="speed" then power=power*1.15 end
            b.vx=clamp((nx*395+p.vx*.52+direction*155)*power,-840,840)
            b.vy=-(rising and 710 or 565)*power
            -- Above-net rising contacts can drive the ball down toward the far court.
            if rising and b.y<S.net-55 and nx*direction>.3 then
              b.vx=direction*780*power; b.vy=160
            end
            p.cooldown=.16
            event(g,rising and "spike" or "hit",b.x,b.y,p.team)
          end
        end
      end
    end
    local speed=math.sqrt(b.vx*b.vx+b.vy*b.vy)
    local cap=g.rule=="speed" and 1320 or 1150
    if speed>cap then b.vx,b.vy=b.vx*cap/speed,b.vy*cap/speed end
    if b.y+b.r>=S.floor then
      if S.lava(g) and S.hazard(b.x) then
        b.y=S.floor-b.r; b.vy=-640
        if math.abs(b.vx)<140 then b.vx=b.x<640 and 190 or -190 end
        event(g,"lava_save",b.x,b.y)
      else point(g,b.x<640 and 2 or 1,b); return end
    end
  end
end
function S.step(g,inputs,dt)
  if g.phase=="finished" then return end
  local oldPlatforms=S.platforms(g)
  g.time=g.time+dt
  local platforms=S.platforms(g)
  if g.phase=="point" then
    g.timer=g.timer-dt
    for _,p in ipairs(g.players) do
      if not p.defeated then playerStep(g,p,p.bot and S.bot(g,p) or (inputs or {})[p.slot],dt,platforms,oldPlatforms) end
    end
    if g.timer<=0 then
      if g.winner then g.phase="finished" else S.serve(g,g.pointTeam) end
    end
    return
  end
  local primary=g.ball
  for _,p in ipairs(g.players) do
    if p.bot then
      local best,cost=primary,math.huge
      for _,b in ipairs(g.balls or {primary}) do
        local own=(p.team==1 and b.x<640) or (p.team==2 and b.x>640)
        local value=(own and 0 or 1200)+math.abs(b.x-p.x)+(S.floor-b.y)*.4+(b.ghost>0 and 1500 or 0)
        if value<cost then best,cost=b,value end
      end
      g.ball=best
    end
    playerStep(g,p,p.bot and S.bot(g,p) or (inputs or {})[p.slot],dt,platforms,oldPlatforms)
    g.ball=primary
  end
  if g.phase=="serve" then
    g.timer=g.timer-dt
    if g.timer<=0 then
      g.phase="play"
      for i,b in ipairs(g.balls or {primary}) do b.vy=-100; if g.rule=="double" then b.vx=i==1 and 120 or -120 end end
      event(g,"serve",primary.x,primary.y,g.serveTeam)
    end
    return
  end
  for _,b in ipairs(g.balls or {primary}) do
    stepBall(g,b,dt,platforms)
    if g.phase~="play" then break end
  end
end
return S
