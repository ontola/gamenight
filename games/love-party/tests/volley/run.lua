return function()
  local S=require("games.volley.sim")
  local count=0
  local function test(name,f) f(); count=count+1; print("PASS "..name) end
  test("shared mode preserves identities, sparse controls and game-owned results",function()
    local M=require("games.volley")
    local players={{slot=2,id="joep",controller="ordinal:1",name="Joep",color="#00ff00",avatar='["#ff0000"]'},
      {slot=4,id="falcon",controller="ordinal:0",name="Falcon",color="#ff00ff"}}
    local g=M.new(players)
    assert(g.players[1].id=="joep" and g.players[1].controller=="ordinal:1" and g.players[1].avatar==players[1].avatar)
    assert(g.players[2].controller=="ordinal:0" and g.players[1].team~=g.players[2].team)
    assert(g.players[1].color=="#00ff00")
    M.finish(g); assert(g.phase=="finished" and M.render)
    local fresh=M.new(players); assert(fresh~=g and fresh.phase=="serve" and fresh.players[1].id=="joep")
  end)
  test("Back requires release and cooldown after resume",function()
    local gate=require("shared.back_gate").new()
    gate:update(1,false); assert(gate:press())
    gate:reset(); gate:update(2,true); assert(not gate:press())
    gate:update(.1,false); assert(not gate:press())
    gate:update(1,false); assert(gate:press()); assert(not gate:press())
  end)
  test("LB jumps and X smashes; B is not smash",function()
    local Input=require("shared.input"); local M=require("games.volley")
    local previous=Input.pads[1]; local down="leftshoulder"
    Input.pads[1]={isConnected=function() return true end,isGamepad=function() return true end,
      isGamepadDown=function(_,...) for _,k in ipairs({...}) do if k==down then return true end end return false end,
      getGamepadAxis=function() return 0 end}
    assert(M.input(1).jump)
    down="x"; assert(M.input(1).smash and not M.input(1).jump)
    down="b"; assert(not M.input(1).smash)
    Input.pads[1]=previous
  end)
  if love.audio and love.sound then
    test("native sound plays after pause and lazy initialization",function()
      local A=require("games.volley.audio")
      A.play("hit"); assert(A.sources.hit:isPlaying())
      A.stop(); A.play("serve"); assert(A.sources.serve:isPlaying()); A.stop()
    end)
  end
  local function empty(opts) opts=opts or {}; opts.seats={}; local g=S.new(opts); g.phase="play"; return g end
  local function ticks(g,n,input) for _=1,n do S.step(g,input or {},1/120); g.events={} end end
  test("aimed smashes: directions, timing, cooldown and obstacles",require("tests.volley.smash"))
  test("round rules, multiball scoring, gravity and lava saves",require("tests.volley.rules"))
  test("floor scores for opponent; first to ten celebrates then ends match",function()
    local g=empty(); g.score[2]=9; g.ball.x=100; g.ball.y=670; g.ball.vy=200
    S.step(g,{},1/120)
    assert(g.score[2]==10 and g.winner==2 and g.phase=="point")
    ticks(g,240); assert(g.phase=="finished" and g.score[2]==10,"finished score must be immutable")
  end)
  test("losing team bursts while winners can still move",function()
    local g=S.new({seats={{slot=1},{slot=2},{slot=3},{slot=4}}})
    g.phase="play"; g.ball.x=80; g.ball.y=680
    S.step(g,{},1/120)
    assert(g.players[1].defeated and g.players[3].defeated)
    assert(not g.players[2].defeated and not g.players[4].defeated)
    local bursts=0; for _,e in ipairs(g.events) do if e.kind=="defeat" then bursts=bursts+1 end end
    assert(bursts==2)
    local before=g.players[2].x
    ticks(g,20,{[2]={move=-1,jump=true}})
    assert(g.players[2].x<before and g.players[2].y<S.floor-S.radius)
  end)
  test("point reset clears bomb and respawns players",function()
    local g=S.new({bomb=true}); g.phase="play"; g.ball.x=80; g.ball.y=680
    S.step(g,{},1/120); assert(g.phase=="point")
    ticks(g,200); assert(g.phase=="serve" and g.serveTeam==2 and g.ball.fuse==6.5)
  end)
  test("holding jump goes higher than tapping",function()
    local held=S.new(); local tap=S.new(); held.phase="play"; tap.phase="play"
    for i=1,25 do S.step(held,{[1]={jump=true}},1/120); S.step(tap,{[1]={jump=i==1}},1/120) end
    assert(held.players[1].y<tap.players[1].y-30)
    assert(held.players[1].y<S.floor-S.radius-60)
  end)
  test("players cannot cross teams or escape walls",function()
    local g=S.new(); ticks(g,240,{[1]={move=1},[2]={move=-1}})
    assert(g.players[1].x<=599 and g.players[2].x>=681)
  end)
  test("high speed ball cannot tunnel through platform",function()
    local g=empty({arena="scaffolding"}); g.ball.x=220; g.ball.y=520; g.ball.vy=1150
    S.step(g,{},1/30)
    assert(g.ball.vy<0 and g.score[1]==0 and g.score[2]==0)
  end)
  test("net reflects a low shot",function()
    local g=empty(); g.ball.x=600; g.ball.y=560; g.ball.vx=1000
    S.step(g,{},1/30); assert(g.ball.vx<0 and g.ball.x<632)
  end)
  test("body contact launches ball; rising contact adds power",function()
    local g=S.new(); g.phase="play"; local p=g.players[1]
    g.ball.x=p.x+12; g.ball.y=p.y-40; g.ball.vy=150
    S.step(g,{},1/120); assert(g.ball.vy< -500 and g.ball.touches==1)
    local h=S.new(); h.phase="play"; local q=h.players[1]
    q.y=420; q.vy=-300; q.grounded=false; h.ball.x=q.x+12; h.ball.y=q.y-40
    S.step(h,{},1/120)
    assert(h.ball.touches==1 and h.events[#h.events].kind=="spike")
    assert(h.ball.vy<g.ball.vy or h.ball.vx>=780)
  end)
  test("bomb blasts without awarding points then reforms",function()
    local g=S.new({bomb=true}); g.phase="play"
    g.ball.x=g.players[1].x; g.ball.y=g.players[1].y-85; g.ball.fuse=.001
    S.step(g,{},1/120)
    assert(g.ball.ghost>0 and g.players[1].vy<0 and g.score[1]+g.score[2]==0)
    ticks(g,100); assert(g.ball.ghost<=0 and g.ball.fuse>6)
  end)
  test("lava knocks player out temporarily",function()
    local g=S.new({arena="lava"}); g.phase="play"; g.players[1].x=260
    S.step(g,{},1/120); assert(g.players[1].out>0)
    ticks(g,164); assert(g.players[1].out<=0 and g.players[1].y<500)
  end)
  test("moving platform carries its standing player",function()
    local g=S.new({arena="elevator"}); local p=g.players[1]; local r=S.platforms(g)[1]
    p.x=r.x+60; p.y=r.y-S.radius; p.grounded=true; p.support=1
    ticks(g,50)
    assert(math.abs(p.y+S.radius-S.platforms(g)[1].y)<.01)
  end)
  test("sparse party seats preserve input IDs and alternate teams",function()
    local G={seats=function(m) return require("games.volley").roster(require("shared.util").players(m.seats,m.players)) end}
    local seats=G.seats({seats={{index=0,occupant={kind="empty"}},{index=1,occupant={kind="local",player_id="a"}},
      {index=3,occupant={kind="ai"}}},players={{id="a",name="Ada",avatar='["#ff0000"]'}}})
    assert(#seats==2 and seats[1].slot==2 and seats[1].team==1 and seats[1].name=="Ada")
    assert(seats[2].slot==4 and seats[2].team==2 and seats[2].bot)
    assert(S.new({seats=seats}).players[1].avatar=='["#ff0000"]')
  end)
  test("studio avatar transparency, legacy faces and invalid input",function()
    local Avatar=require("games.volley.avatar")
    local json=require("vendor.json")
    local current=Avatar.parse('{"v":1,"w":2,"h":2,"px":["#0f172a",null,"#ff0000",null]}')
    assert(current and current.px[1] and not current.px[2] and current.px[3] and not current.px[4])
    local old=Avatar.parse('["#0f172a","#ff0000","#0F172A","invalid"]')
    assert(old and not old.px[1] and old.px[2] and not old.px[3] and not old.px[4])
    assert(json.encode(json.decode('[null,"#ff0000",null]'))=='[null,"#ff0000",null]')
    for _,bad in ipairs({'','null','[]','["#0f172a"]','[null]','{"v":2,"w":1,"h":1,"px":["#ffffff"]}',
      '{"v":1,"w":257,"h":1,"px":[]}','{"v":1,"w":2,"h":2,"px":["#ffffff"]}'}) do assert(not Avatar.parse(bad),bad) end
    for _,face in ipairs(require("tests.volley.faces")) do
      local art=Avatar.parse(face); assert(art and art.w==48 and art.maxx-art.minx<15)
      if love and love.graphics then
        local img=Avatar.image(face); assert(img and img:getWidth()==48)
        local min,mag=img:getFilter(); assert(min=="nearest" and mag=="nearest")
      end
    end
  end)
  test("AI receives serves, moving shots and wall rebounds",require("tests.volley.ai"))
  test("four courts survive five minutes of bot play each",function()
    for _,arena in ipairs(S.arenas) do
      for _,bomb in ipairs({false,true}) do
        local opts={arena=arena.id,bomb=bomb,target=21,seats={{slot=1,bot=true},{slot=2,bot=true},{slot=3,bot=true},{slot=4,bot=true}}}
        local g=S.new(opts); local points=0
        for _=1,36000 do
          S.step(g,{},1/120); g.events={}
          for _,p in ipairs(g.players) do assert(p.x==p.x and p.y==p.y and math.abs(p.y)<2000) end
          assert(g.ball.x==g.ball.x and g.ball.y==g.ball.y and g.ball.y<800)
          if g.phase=="finished" then points=points+g.score[1]+g.score[2]; g=S.new(opts) end
        end
        -- Competent bots can sustain a long rally; repeated contacts also prove liveness.
        assert(points+g.score[1]+g.score[2]>0 or g.ball.touches>20,"stalled court: "..arena.id)
      end
    end
  end)
  print(count.." simulation checks passed")
end
