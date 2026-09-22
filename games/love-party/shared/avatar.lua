-- Matches crates/gamenight-protocol/src/avatar.rs, including old studio drawings.
local json=require("vendor.json")
local Avatar={}
function Avatar.parse(payload)
  if type(payload)~="string" or #payload>1024*1024 then return end
  local ok,o=pcall(json.decode,payload)
  if not ok or type(o)~="table" then return end
  local w,h,px,legacy
  if payload:match("^%s*%[") then
    px=o; w=math.sqrt(#o); h=w; legacy=true
  else
    if o.v~=1 or type(o.px)~="table" then return end
    w,h,px=o.w,o.h,o.px
  end
  if type(w)~="number" or type(h)~="number" or w%1~=0 or h%1~=0 or w<1 or h<1 or w>256 or h>256 or #px~=w*h then return end
  local result={w=w,h=h,px={},minx=w,miny=h,maxx=-1,maxy=-1}
  for i=1,w*h do
    local s=px[i]
    if legacy and type(s)~="string" then return end
    if type(s)=="string" and not (legacy and s:lower()=="#0f172a") then
      local hex=s:match("^%s*#*([%x][%x][%x][%x][%x][%x])%s*$")
      if hex then
        result.px[i]={tonumber(hex:sub(1,2),16)/255,tonumber(hex:sub(3,4),16)/255,tonumber(hex:sub(5,6),16)/255}
        local x,y=(i-1)%w,math.floor((i-1)/w)
        result.minx=math.min(result.minx,x); result.miny=math.min(result.miny,y)
        result.maxx=math.max(result.maxx,x); result.maxy=math.max(result.maxy,y)
      end
    end
  end
  if result.maxx<0 then return end
  return result
end
function Avatar.image(payload)
  local art=Avatar.parse(payload); if not art then return end
  -- Preserve the studio canvas: accessory padding is meaningful positioning.
  local w,h=art.w,art.h
  local data=love.image.newImageData(w,h)
  for y=0,h-1 do for x=0,w-1 do
    local c=art.px[y*w+x+1]
    if c then data:setPixel(x,y,c[1],c[2],c[3],1) end
  end end
  local image=love.graphics.newImage(data)
  image:setFilter("nearest","nearest")
  return image
end
return Avatar
