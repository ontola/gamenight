local B={id="bubble-buddies",title="BUBBLE BUDDIES",floor=646,left=64,right=1216,ceiling=188}
local radii={18,32,52}; local bounce={-355,-485,-605}; local speed={215,165,120}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function bubble(size,x,y,dir) return {size=size,x=x,y=y,r=radii[size],vx=dir*speed[size],vy=bounce[size]} end
function B.wave(g,n)
  g.wave=n; g.bubbles={}; g.ropes={}; g.clock=80; g.phase="ready"; g.timer=1.5
  for i=1,math.min(4,n+1) do
    g.bubbles[i]=bubble(n<3 and 2 or 3,130+i*190,245+(i%2)*55,i%2==0 and 1 or -1)
  end
  for i,p in ipairs(g.players) do p.x=210+(i-1)*270; p.out=0; p.invuln=2; p.cooldown=0 end
end
function B.new(seats)
  local g={players={},hearts=6,phase="play",events={},time=0,popped=0,flash=0}
  for _,s in ipairs(seats) do g.players[#g.players+1]={slot=s.slot,name=s.name,avatar=s.avatar,bot=s.bot} end
  B.wave(g,1); return g
end
function B.obstacles(g)
  if g.wave==2 or g.wave==4 then return {{x=510,y=362,w=260,h=18}} end
  if g.wave>=3 then return {{x=260+math.sin(g.time*.5)*95,y=380,w=180,h=18},{x=835-math.sin(g.time*.5)*95,y=330,w=180,h=18}} end
  return {}
end
function B.bot(g,p)
  local best,score=0,-math.huge
  for _,move in ipairs({0,-1,1}) do
    local x=clamp(p.x+move*85,88,1192)
    local risk=0; local nearest=1000
    for _,b in ipairs(g.bubbles) do
      local futureX=b.x+b.vx*.25
      local futureY=b.y+b.vy*.25+390*.25*.25
      if futureY>B.floor-b.r then futureY=B.floor-b.r end
      local gap=math.abs(x-futureX)
      if futureY>B.floor-115 then risk=risk+math.max(0,b.r+72-gap)*5 end
      nearest=math.min(nearest,math.abs(x-b.x))
    end
    local value=-risk-nearest*.10-math.abs(x-p.x)*.015
    if value>score then best,score=move,value end
  end
  return {move=best,fire=true}
end
function B.step(g,inputs,dt)
  if g.phase=="won" or g.phase=="lost" then return end
  g.time=g.time+dt; g.flash=math.max(0,g.flash-dt)
  if g.phase=="ready" or g.phase=="clear" then
    g.timer=g.timer-dt
    if g.timer<=0 then
      if g.phase=="clear" then
        if g.wave>=5 then g.phase="won" else g.hearts=math.min(6,g.hearts+1); B.wave(g,g.wave+1) end
      else g.phase="play" end
    end
    return
  end
  g.clock=g.clock-dt
  if g.clock<=0 then g.phase="lost"; g.reason="TIME RAN OUT"; return end
  for _,p in ipairs(g.players) do
    p.out=math.max(0,p.out-dt); p.invuln=math.max(0,p.invuln-dt); p.cooldown=math.max(0,p.cooldown-dt)
    if p.out<=0 then
      local a=p.bot and B.bot(g,p) or (inputs[p.slot] or {})
      p.x=clamp(p.x+(a.move or 0)*300*dt,88,1192)
      if a.fire and p.cooldown<=0 then
        local active=false; for _,r in ipairs(g.ropes) do if r.slot==p.slot then active=true end end
        if not active then g.ropes[#g.ropes+1]={x=p.x,y=B.floor-40,life=1.05,slot=p.slot}; p.cooldown=.28; g.events[#g.events+1]="fire" end
      end
    end
  end
  for i=#g.ropes,1,-1 do
    local r=g.ropes[i]; r.y=math.max(B.ceiling,r.y-900*dt); r.life=r.life-dt
    if r.life<=0 then table.remove(g.ropes,i) end
  end
  local blocks=B.obstacles(g)
  for _,b in ipairs(g.bubbles) do
    local oldBottom=b.y+b.r
    b.vy=b.vy+780*dt; b.x=b.x+b.vx*dt; b.y=b.y+b.vy*dt
    if b.x-b.r<B.left then b.x=B.left+b.r; b.vx=math.abs(b.vx) end
    if b.x+b.r>B.right then b.x=B.right-b.r; b.vx=-math.abs(b.vx) end
    if b.y-b.r<B.ceiling then b.y=B.ceiling+b.r; b.vy=math.abs(b.vy) end
    if b.y+b.r>=B.floor then b.y=B.floor-b.r; b.vy=bounce[b.size] end
    for _,r in ipairs(blocks) do
      if b.vy>0 and oldBottom<=r.y and b.y+b.r>=r.y and b.x>r.x-b.r*.5 and b.x<r.x+r.w+b.r*.5 then b.y=r.y-b.r; b.vy=bounce[b.size] end
    end
  end
  for i=#g.bubbles,1,-1 do
    local b=g.bubbles[i]; local popped=false
    for j=#g.ropes,1,-1 do
      local r=g.ropes[j]
      if math.abs(b.x-r.x)<b.r+4 and b.y+b.r>=r.y then
        table.remove(g.bubbles,i); table.remove(g.ropes,j)
        if b.size>1 then
          g.bubbles[#g.bubbles+1]=bubble(b.size-1,b.x-5,b.y,-1)
          g.bubbles[#g.bubbles+1]=bubble(b.size-1,b.x+5,b.y,1)
        end
        g.popped=g.popped+1; g.events[#g.events+1]="pop"; popped=true; break
      end
    end
    if not popped then for _,p in ipairs(g.players) do
      if p.out<=0 and p.invuln<=0 and (b.x-p.x)^2+(b.y-(B.floor-25))^2<(b.r+23)^2 then
        g.hearts=g.hearts-1; p.out=1.2; p.invuln=3; g.flash=.3; g.events[#g.events+1]="hurt"
        if g.hearts<=0 then g.phase="lost"; g.reason="THE TEAM RAN OUT OF HEARTS"; return end
      end
    end end
  end
  if #g.bubbles==0 then g.phase="clear"; g.timer=1.5; g.events[#g.events+1]="clear" end
end
return B
