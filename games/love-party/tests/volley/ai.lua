return function()
  local S=require("games.volley.sim")
  local shots={
    {x=960,y=250,vx=0,vy=100},
    {x=830,y=260,vx=160,vy=160},
    {x=1120,y=280,vx=-240,vy=80},
    {x=1120,y=260,vx=390,vy=60}, -- Bounce off the back wall.
    {x=490,y=230,vx=470,vy=20}, -- Move before the ball crosses the net.
    {x=720,y=290,vx=260,vy=150},
  }
  local saves=0
  for i,shot in ipairs(shots) do
    local g=S.new({seats={{slot=2,bot=true}}}); g.phase="play"
    for k,v in pairs(shot) do g.ball[k]=v end
    local saved=false
    for _=1,420 do
      S.step(g,{},1/120)
      if g.ball.touches>0 then saved=true; break end
      if g.phase~="play" then break end
    end
    if saved then saves=saves+1 end
    print("AI reception "..i..": "..(saved and "saved" or "missed"))
  end
  assert(saves>=5,"AI must receive at least five of six reachable shots; got "..saves)
  local g=S.new({seats={{slot=2,bot=true}}}); g.phase="play"
  g.ball.x,g.ball.y,g.ball.vx,g.ball.vy=490,230,470,20
  local p=g.players[1]; p.x=1100
  assert(S.bot(g,p).move<0,"anticipate incoming ball before it crosses the net")
end
