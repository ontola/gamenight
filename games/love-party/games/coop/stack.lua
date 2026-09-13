-- A shared twelve-column well. Each player owns six columns; rows clear together.
local T={id="stack-together",title="STACK TOGETHER",width=12,height=18}
local shapes={{{0,0},{1,0},{2,0},{3,0}},{{0,0},{1,0},{0,1},{1,1}},
  {{1,0},{0,1},{1,1},{2,1}},{{1,0},{2,0},{0,1},{1,1}},
  {{0,0},{1,0},{1,1},{2,1}},{{0,0},{0,1},{1,1},{2,1}},{{2,0},{0,1},{1,1},{2,1}}}
function T.cells(kind,rot)
  local c={}; local minx,miny=10,10
  for _,v in ipairs(shapes[kind]) do
    local x,y=v[1],v[2]
    for _=1,rot do x,y=-y,x end
    c[#c+1]={x,y}; minx=math.min(minx,x); miny=math.min(miny,y)
  end
  for _,v in ipairs(c) do v[1]=v[1]-minx; v[2]=v[2]-miny end
  return c
end
function T.fits(g,p,x,y,rot)
  for _,v in ipairs(T.cells(p.kind,rot)) do
    local cx,cy=x+v[1],y+v[2]
    if cx<p.lane or cx>p.lane+5 or cy>T.height then return false end
    if cy>0 and g.board[cy][cx] then return false end
  end
  return true
end
local function random(g,n) g.seed=(g.seed*48271)%2147483647; return g.seed%n+1 end
local function nextPiece(g,p)
  if #p.bag==0 then
    p.bag={1,2,3,4,5,6,7}
    for i=7,2,-1 do local j=random(g,i); p.bag[i],p.bag[j]=p.bag[j],p.bag[i] end
  end
  return table.remove(p.bag)
end
function T.spawn(g,p)
  p.kind=p.next or nextPiece(g,p); p.next=nextPiece(g,p)
  p.x,p.y,p.rot,p.fall,p.repeatTime=p.lane+1,1,0,0,0
  p.ai=nil; p.age=0
  if not T.fits(g,p,p.x,p.y,0) then g.phase="lost"; g.reason="THE STACK REACHED THE TOP" end
end
function T.new(seats,seed)
  local g={board={},players={},rows=0,target=12,phase="play",time=0,seed=seed or 7381,events={},flash=0}
  for y=1,T.height do g.board[y]={} end
  for i,s in ipairs(seats) do if i<=2 then
    g.players[i]={slot=s.slot,name=s.name,avatar=s.avatar,bot=s.bot,lane=(i-1)*6+1,bag={},previous={}}
  end end
  for _,p in ipairs(g.players) do T.spawn(g,p) end
  return g
end
function T.clear(g)
  local n=0
  for y=T.height,1,-1 do
    local full=true; for x=1,T.width do if not g.board[y][x] then full=false; break end end
    if full then
      table.remove(g.board,y); n=n+1
      -- Active pieces above a cleared row fall with the settled stack.
      for _,p in ipairs(g.players) do if p.y<y then p.y=p.y+1 end end
    end
  end
  for _=1,n do table.insert(g.board,1,{}) end
  if n>0 then
    -- Inserting empty top rows shifts all remaining coordinates down n cells.
    -- Active pieces already moved once per removed row above; no second shift.
    g.rows=g.rows+n; g.flash=.6; g.events[#g.events+1]="clear"
    if g.rows>=g.target then g.phase="won" end
  end
  return n
end
local function lock(g,p)
  for _,v in ipairs(T.cells(p.kind,p.rot)) do
    local x,y=p.x+v[1],p.y+v[2]
    if y<1 then g.phase="lost"; return end
    g.board[y][x]=p.kind
  end
  g.events[#g.events+1]="lock"
  T.clear(g)
  if g.phase=="play" then T.spawn(g,p) end
end
function T.dropY(g,p,x,rot)
  local y=p.y
  if not T.fits(g,p,x,y,rot) then return nil end
  while T.fits(g,p,x,y+1,rot) do y=y+1 end
  return y
end
local function plan(g,p)
  local best,cost=nil,math.huge
  for r=0,3 do for x=p.lane,p.lane+5 do
    local y=T.dropY(g,p,x,r)
    if y then
      local added={}; for _,v in ipairs(T.cells(p.kind,r)) do added[(y+v[2])*20+x+v[1]]=true end
      local function filled(cx,cy) return g.board[cy][cx] or added[cy*20+cx] end
      local heights,holes,complete={},0,0
      for cx=p.lane,p.lane+5 do
        local top=0
        for cy=1,T.height do
          if filled(cx,cy) and top==0 then top=T.height-cy+1
          elseif not filled(cx,cy) and top>0 then holes=holes+1 end
        end
        heights[#heights+1]=top
      end
      for cy=1,T.height do
        local full=true; for cx=p.lane,p.lane+5 do if not filled(cx,cy) then full=false end end
        if full then complete=complete+1 end
      end
      local score=holes*18-complete*11
      for i,h in ipairs(heights) do score=score+h*.65+h*h*.05; if i>1 then score=score+math.abs(h-heights[i-1])*.7 end end
      if score<cost then best,cost={x=x,rot=r},score end
    end
  end end
  return best
end
function T.bot(g,p)
  if not p.ai then p.ai=plan(g,p) end
  if not p.ai then return {drop=true} end
  -- Release rotate/drop between presses; bots use exactly the human move rules.
  if p.rot~=p.ai.rot then return {rotate=not p.previous.rotate} end
  if p.x~=p.ai.x then return {move=p.x<p.ai.x and 1 or -1} end
  local own,other=0,0
  for _,row in ipairs(g.board) do for x in pairs(row) do
    if x>=p.lane and x<p.lane+6 then own=own+1 else other=other+1 end
  end end
  -- Let a slower human catch up instead of hard-dropping a tower on their behalf.
  return {drop=own-other<=12 and p.age>.7 and not p.previous.drop}
end
function T.step(g,inputs,dt)
  if g.phase~="play" then return end
  g.time=g.time+dt; g.flash=math.max(0,g.flash-dt)
  for _,p in ipairs(g.players) do
    p.age=p.age+dt
    local a=p.bot and T.bot(g,p) or (inputs[p.slot] or {})
    local move=a.move or 0
    if move~=0 then
      p.repeatTime=p.repeatTime-dt
      if move~=p.previous.move or p.repeatTime<=0 then
        if T.fits(g,p,p.x+move,p.y,p.rot) then p.x=p.x+move end
        p.repeatTime=move~=p.previous.move and .19 or .075
      end
    else p.repeatTime=0 end
    if a.rotate and not p.previous.rotate then
      local r=(p.rot+1)%4
      for _,kick in ipairs({0,-1,1,-2,2}) do
        if T.fits(g,p,p.x+kick,p.y,r) then p.x,p.rot=p.x+kick,r; break end
      end
    end
    if a.drop and not p.previous.drop then p.y=T.dropY(g,p,p.x,p.rot) or p.y; lock(g,p)
    else
      p.fall=p.fall+dt
      local interval=a.down and .045 or math.max(.26,.85-g.rows*.025)
      if p.fall>=interval then
        p.fall=0
        if T.fits(g,p,p.x,p.y+1,p.rot) then p.y=p.y+1 else lock(g,p) end
      end
    end
    p.previous={move=move,rotate=a.rotate,drop=a.drop}
    if g.phase~="play" then break end
  end
end
return T
