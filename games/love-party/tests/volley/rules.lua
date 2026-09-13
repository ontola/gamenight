return function()
  local S=require("games.volley.sim")
  local g=S.new({variety=true,seats={}})
  for i=1,11 do
    assert(g.rule==S.rules[(i-1)%5+1])
    assert(#g.balls==(g.rule=="double" and 2 or 1))
    S.serve(g,1)
  end
  g=S.new({rule="double",seats={}}); g.phase="play"
  g.balls[2].x,g.balls[2].y=1100,680
  S.step(g,{},1/120); assert(g.score[1]==1 and g.phase=="point","second ball scores")
  g=S.new({rule="double",seats={}}); g.phase="play"
  for _,b in ipairs(g.balls) do b.y=680 end
  S.step(g,{},1/120); assert(g.score[1]+g.score[2]==1,"one point per rally")
  g=S.new({rule="lava",seats={}}); g.phase="play"; g.ball.x,g.ball.y=250,680
  S.step(g,{},1/120); assert(g.ball.vy<0 and g.score[1]+g.score[2]==0 and g.phase=="play")
  g.ball.x,g.ball.y=100,680; S.step(g,{},1/120); assert(g.score[2]==1,"ordinary floor still scores")
  local moon=S.new({rule="moon",seats={{slot=1}}}); local normal=S.new({seats={{slot=1}}})
  moon.phase,normal.phase="play","play"
  for _=1,25 do S.step(moon,{[1]={jump=true}},1/120); S.step(normal,{[1]={jump=true}},1/120) end
  assert(moon.players[1].y<normal.players[1].y and moon.ball.y<normal.ball.y)
  g=S.new({rule="speed",seats={}}); assert(g.ball.r==14)
  g=S.new({seats={{slot=1}}}); for _=1,30 do S.step(g,{[1]={move=1}},1/120) end
  assert(g.players[1].vx==650,"increased movement speed")
  assert(S.hazard(290) and S.hazard(990))
  assert(not S.hazard(220) and not S.hazard(360) and not S.hazard(915) and not S.hazard(1060),"smaller lava patches leave safe floor")
  for _,rule in ipairs(S.rules) do
    for _,bomb in ipairs({false,true}) do
      g=S.new({rule=rule,bomb=bomb,target=21,seats={{slot=1,bot=true},{slot=2,bot=true}}})
      for _=1,7200 do
        S.step(g,{},1/120); g.events={}
        for _,b in ipairs(g.balls) do assert(b.x==b.x and b.y==b.y and b.y<800) end
      end
    end
  end
end
