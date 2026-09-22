-- GameNight head coordinates. x/y always mean the centre of the skin circle.
local Avatar=require("shared.avatar")
local Face={CENTER_X=24,CENTER_Y=28,RADIUS=12,CANVAS=48}
local cache=setmetatable({}, {__mode="k"})
function Face.placement(w,h,x,y,radius,facing)
  local scale=radius/Face.RADIUS
  -- Older small canvases used these offsets in the studio's 48px canvas.
  local ox=w==32 and 14 or w==16 and 22 or (48-w)/2
  local oy=h==32 and 15 or h==16 and 23 or (48-h)/2
  return x,y,scale*(facing==-1 and -1 or 1),scale,Face.CENTER_X-ox,Face.CENTER_Y-oy
end
local function skin(value)
  if type(value)=="string" and value:match("^#%x%x%x%x%x%x$") then
    return tonumber(value:sub(2,3),16)/255,tonumber(value:sub(4,5),16)/255,tonumber(value:sub(6,7),16)/255
  end
  return 245/255,233/255,190/255
end
function Face.drawFace(player,x,y,radius,options)
  options=options or {}; radius=radius or 12
  local g=love.graphics
  g.push("all"); g.translate(x,y); g.rotate(options.rotation or 0)
  g.setColor(skin(player.skin_color)); g.circle("fill",0,0,radius)
  local entry=cache[player]
  if not entry or entry.payload~=player.avatar then
    entry={payload=player.avatar,image=Avatar.image(player.avatar)};cache[player]=entry
  end
  if entry.image then
    local w,h=entry.image:getDimensions()
    local dx,dy,sx,sy,ox,oy=Face.placement(w,h,0,0,radius,options.facing)
    g.setColor(1,1,1,1);g.draw(entry.image,dx,dy,0,sx,sy,ox,oy)
  else
    g.scale(radius/12,radius/12);g.scale(options.facing==-1 and -1 or 1,1)
    g.setColor(.08,.09,.12,1)
    g.circle("fill",0,-2,1.2);g.circle("fill",6,-2,1.2)
    g.setLineWidth(1);g.line(2,5,6,5)
  end
  g.pop()
end
return Face
