local Input=require("shared.input")
local Audio=require("shared.audio")
local V=require("games.coop.view")
return function(module)
 local M={id=module.id,title=module.title,tagline="One very cooperative couch",controls="Move / A action / B drop",duration=math.huge,coop=true}
 function M.new(players)
  local s=module.new(players)
  for i,p in ipairs(s.players) do
   local identity=players[i]
   p.id,p.controller,p.color,p.skin_color=identity.id,identity.controller,identity.color,identity.skin_color
   p.score=0
  end
  s.presentation={game=s,module=module,screen="play",managed=true}
  return s
 end
 function M.input(slot)
  local v=Input.sample(slot)
  return {move=v.x<-.35 and -1 or v.x>.35 and 1 or 0,rotate=v.action or v.y<-.35,down=v.y>.35,drop=v.secondary,fire=v.action}
 end
 function M.bot(s,p) return module.bot(s,p) end
 function M.update(s,dt,inputs)
  local bySlot={};for i,p in ipairs(s.players) do bySlot[p.slot]=inputs[i] end
  module.step(s,bySlot,dt)
  for _,event in ipairs(s.events) do Audio.play(event=="pop" and "hit" or event=="clear" and "point" or event) end
  s.events={};s.over=s.phase=="won" or s.phase=="lost"
 end
 function M.finish(s) if not s.over then s.phase="won" end end
 function M.render(s)
  local w,h=love.graphics.getDimensions();local scale=math.min(w/1280,h/800)
  love.graphics.clear(.03,.04,.08);love.graphics.push()
  love.graphics.translate((w-1280*scale)/2,(h-800*scale)/2);love.graphics.scale(scale)
  V.draw(s.presentation);love.graphics.pop()
 end
 return M
end
