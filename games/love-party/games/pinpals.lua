local Input=require("shared.input")
local Face=require("shared.face")
local M={id="pinpals",title="Pinpals",tagline="Two boards. One shared ball.",controls="LB/RB flippers / A gate / B paddle",duration=math.huge,coop=true}
local Match,Render,Audio,FX,Intents,defs
function M.load()
 if not love.filesystem.getInfo("core/constants.lua") then
  assert(love.filesystem.mount(love.filesystem.getSourceBaseDirectory().."/pinpals","",true),"Pinpals source missing")
 end
 Match=require("sim.match");Render=require("app.render");Audio=require("app.audio");FX=require("app.fx");Intents=require("core.intents")
 defs=require("data.tables.init").load()
 if love.graphics then Render.load(defs);Render.attach_fx(FX) end
 Audio.load()
end
function M.new(players)
 if not Match then M.load() end
 FX.reset()
 return {players=players,match=Match.new(defs,os.time()),previous={}}
end
function M.input(slot)
 local v=Input.sample(slot);local pad=Input.pads[slot]
 return {flip_left=(pad and pad:isConnected() and pad:isGamepadDown("leftshoulder")) or v.x<-.35,
 flip_right=(pad and pad:isConnected() and pad:isGamepadDown("rightshoulder")) or v.x>.35,
 operator_gate=v.action or v.y<-.35,operator_paddle=v.secondary or v.y>.35}
end
function M.bot() return {} end
function M.update(s,dt,inputs)
 for i in ipairs(s.players) do
  if i<=2 then
   local now=inputs[i] or {};local previous=s.previous[i] or {}
   for action in pairs(Intents.ACTIONS) do
    local pressed=now[action]==true
    if pressed~=(previous[action]==true) then s.match:push(Intents.new(i,action,pressed,s.match.state.tick)) end
   end
   s.previous[i]=now
  end
 end
 s.match:advance(dt);local events=s.match:drain_events()
 Audio.update(s.match,events);FX.update(s.match,events,dt)
 if love.graphics then Render.update_camera(s.match.state,defs,dt) end
end
function M.dispose(s)
 if s then for _,board in pairs(s.match.boards) do board.world:destroy() end end
 FX.reset()
end
function M.mute() if love.audio then love.audio.stop() end end
function M.render(s)
 local labels={}
 for i=1,2 do local p=s.players[i]; labels[i]={name=p and p.name or "Empty",empty=p==nil,flip_left="LB",flip_right="RB",operator_gate="A",operator_paddle="B"} end
 Render.draw(s.match,labels)
 local w=love.graphics.getWidth()
 for i,p in ipairs(s.players) do
  if i<=2 then Face.drawFace(p,(i-.5)*w/2,46,18,{outline=p.color}) end
 end
end
return M
