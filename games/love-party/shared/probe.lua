-- Opt-in observations for executable contract tests. In normal play this is inert.
local P = {steps=0, inputs={}, rendered={text={}, colors={}, faces={}}}
local path=os.getenv("GNLOVE_PROBE_FILE")
if not path then
  function P.install() end
  function P.step() end
  function P.observe() end
  return P
end
local json=require("vendor.json")
local images=setmetatable({}, {__mode="k"})
function P.install()
  local pads={}
  for i=1,2 do
    local index=i
    pads[i]={probeOrdinal=i-1, isConnected=function() return true end,
      isGamepad=function() return true end,
      getGamepadAxis=function(_,axis) return axis=="leftx" and (index==1 and -1 or 1) or 0 end,
      isGamepadDown=function(_,key) return index==1 and (key=="a" or key=="leftshoulder") or index==2 and (key=="b" or key=="rightshoulder") end}
  end
  love.joystick.getJoysticks=function() return pads end
  love.keyboard.isDown=function() return false end
  if not love.graphics then return end
  local avatar=require("games.volley.avatar")
  local make=avatar.image
  avatar.image=function(payload)
    local image=make(payload)
    if image then images[image]=payload end
    return image
  end
  for _,name in ipairs({"print","printf"}) do
    local original=love.graphics[name]
    love.graphics[name]=function(value,...)
      if type(value)=="string" then P.rendered.text[value]=true end
      return original(value,...)
    end
  end
  local color=love.graphics.setColor
  love.graphics.setColor=function(r,g,b,a)
    local v=type(r)=="table" and r or {r,g,b,a}
    if v[1] and v[2] and v[3] then
      local hex=string.format("#%02x%02x%02x", math.floor(v[1]*255+.5),math.floor(v[2]*255+.5),math.floor(v[3]*255+.5))
      P.rendered.colors[hex]=true
    end
    return color(r,g,b,a)
  end
  local draw=love.graphics.draw
  love.graphics.draw=function(image,...)
    if images[image] then P.rendered.faces[images[image]]=true end
    return draw(image,...)
  end
end
function P.step(inputs)
  P.steps=P.steps+1
  P.inputs=inputs
end
function P.observe(phase,state)
  local players={}
  for i,p in ipairs(state and state.players or {}) do
    local pad=require("shared.input").pads[p.slot]
    players[i]={id=p.id,name=p.name,color=p.color,skin_color=p.skin_color,avatar=p.avatar,
      slot=p.slot,controller=p.controller,pad=pad and pad.probeOrdinal}
  end
  P.frames=(P.frames or 0)+1
  local snapshot={frames=P.frames,phase=phase,players=players,steps=P.steps,inputs=P.inputs,rendered=P.rendered,
    visible=love.window and love.window.isVisible() or false,
    audio=love.audio and love.audio.getActiveSourceCount() or 0}
  local f=assert(io.open(path,"w")); f:write(json.encode(snapshot)); f:close()
end
return P
