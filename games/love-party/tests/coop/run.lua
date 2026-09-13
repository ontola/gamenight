return function()
  local T,B=require("games.coop.stack"),require("games.coop.bubbles")
  local seats={{slot=1,name="P1"},{slot=2,name="P2"}}
  local n=0
  local function check(name,f) f(); n=n+1; print("PASS "..name) end
  check("a half row waits for the teammate",function()
    local g=T.new(seats)
    for x=1,6 do g.board[18][x]=1 end
    assert(T.clear(g)==0 and g.rows==0)
    for x=7,12 do g.board[18][x]=2 end
    assert(T.clear(g)==1 and g.rows==1 and #g.board==18)
  end)
  check("multiple rows clear and stacks settle",function()
    local g=T.new(seats); g.board[16][3]=4
    for y=17,18 do for x=1,12 do g.board[y][x]=2 end end
    assert(T.clear(g)==2 and g.board[18][3]==4)
  end)
  check("piece movement cannot cross the shared seam",function()
    local g=T.new(seats); local p=g.players[1]
    assert(not T.fits(g,p,7,3,0))
    p=g.players[2]; assert(not T.fits(g,p,4,3,0))
  end)
  check("hard drop locks four cells and produces the next piece",function()
    local g=T.new(seats); T.step(g,{[1]={drop=true}},1/120)
    local count=0; for _,r in ipairs(g.board) do for _ in pairs(r) do count=count+1 end end
    assert(count==4 and g.players[1].y==1)
  end)
  check("shared target wins and terminal state freezes",function()
    local g=T.new(seats); g.rows=11
    for x=1,12 do g.board[18][x]=2 end
    T.clear(g); assert(g.phase=="won")
    local time=g.time; T.step(g,{},1); assert(g.time==time)
  end)
  check("blocked spawn loses cleanly",function()
    local g=T.new(seats)
    for y=1,4 do for x=1,6 do g.board[y][x]=1 end end
    T.spawn(g,g.players[1]); assert(g.phase=="lost")
  end)
  check("large bubbles split into exactly two smaller bubbles",function()
    local g=B.new(seats); g.phase="play"
    g.bubbles={{size=3,x=600,y=300,r=52,vx=0,vy=0}}
    g.ropes={{slot=1,x=600,y=280,life=1}}
    B.step(g,{},1/120)
    assert(#g.bubbles==2 and g.bubbles[1].size==2 and g.bubbles[2].size==2 and g.popped==1)
  end)
  check("last small bubble clears wave and restores a shared heart",function()
    local g=B.new(seats); g.phase="play"; g.hearts=4
    g.bubbles={{size=1,x=600,y=300,r=18,vx=0,vy=0}}; g.ropes={{slot=1,x=600,y=280,life=1}}
    B.step(g,{},1/120); assert(g.phase=="clear")
    B.step(g,{},1.6); assert(g.wave==2 and g.hearts==5)
  end)
  check("damage shares hearts and respects invulnerability",function()
    local g=B.new(seats); g.phase="play"; local p=g.players[1]; p.invuln=0
    g.bubbles={{size=1,x=p.x,y=B.floor-25,r=18,vx=0,vy=0}}
    B.step(g,{},1/120); assert(g.hearts==5 and p.out>0)
    B.step(g,{},1/120); assert(g.hearts==5)
  end)
  check("timer and fifth wave produce terminal results",function()
    local g=B.new(seats); g.phase="play"; g.clock=.001; B.step(g,{},1/120); assert(g.phase=="lost")
    g=B.new(seats); g.phase="clear"; g.wave=5; g.timer=.001; B.step(g,{},1/120); assert(g.phase=="won")
  end)
  check("CPU crews can clear rows and pop bubbles",function()
    local bots={{slot=1,bot=true},{slot=2,bot=true}}
    local rows,pops=0,0
    for seed=1,5 do
      local g=T.new(bots,seed*1723)
      for _=1,14400 do T.step(g,{},1/120); g.events={} end
      rows=rows+g.rows
    end
    local g=B.new(bots)
    for _=1,14400 do B.step(g,{},1/120); g.events={} end
    pops=g.popped
    print("CPU rows:",rows,"bubbles:",pops,"wave:",g.wave)
    assert(rows>=5 and pops>=8)
  end)
  print(n.." co-op checks passed")
end
