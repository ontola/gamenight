-- Softened inverse-square fields: bounded at the core and frame-rate independent.
local M = {}
function M.fields(s)
 local t=s.time
 local fields={}
 if s.wave>=1 then fields[1]={x=s.width*(0.30+0.045*math.sin(t*0.22)),y=s.height*(0.30+0.06*math.cos(t*0.18)),mass=1600000*math.min(1,s.wave/4),r=19} end
 if s.wave>=5 then fields[#fields+1]={x=s.width*0.73,y=s.height*0.67,mass=6500000,r=24,lethal=true} end
 return fields
end
function M.portals(s)
 if s.wave<3 then return {} end
 return {{x=s.width*0.12,y=s.height*0.70,r=25},{x=s.width*0.88,y=s.height*0.28,r=25}}
end
function M.strength(s) return math.min(1,math.max(0,(s.time-3)/3)) end
function M.force(s,x,y)
 local ax,ay=0,0
 for _,f in ipairs(M.fields(s)) do
  local dx,dy=f.x-x,f.y-y
  local d2=dx*dx+dy*dy+65*65
  local ramp=f.lethal and math.min(1,math.max(0,(s.waveClock-1)/3)) or 1
  if s.wave>5 then ramp=1 end
  local a=f.mass/(d2*math.sqrt(d2))*M.strength(s)*ramp
  ax,ay=ax+dx*a,ay+dy*a
 end
 return ax,ay
end
function M.warp(s,x,y)
 local ox,oy=0,0
 for _,f in ipairs(M.fields(s)) do
  local dx,dy=f.x-x,f.y-y
  local k=0.42*math.exp(-(dx*dx+dy*dy)/(180*180))*M.strength(s)
  ox,oy=ox+dx*k,oy+dy*k
 end
 return x+ox,y+oy
end
-- Three staggered generations disappear before their coordinates reset.
-- One phase per source keeps each grid coherent; local falloff increases
-- displacement near the core without introducing phase seams along a line.
function M.flowSample(s,f,x,y,layer)
 local strength=M.strength(s)
 local ramp=f.lethal and s.wave==5 and math.min(1,math.max(0,(s.waveClock-1)/3)) or 1
 local intensity=math.min(2.5,f.mass/1600000)*strength*ramp
 local phase=(s.time*(0.32+intensity*0.48)+layer/3)%1
 local dx,dy=f.x-x,f.y-y
 local falloff=math.max(0,1-(dx*dx+dy*dy)/(260*260))^2
 local pull=math.min(0.78,intensity*0.32)*phase*falloff
 local alpha=math.sin(math.pi*phase)^2*falloff*math.min(1,intensity)*0.45
 return x+dx*pull,y+dy*pull,alpha
end
local flowMesh,flowCapacity
function M.drawFlow(s,G)
 local vertices={}
 local function segment(f,x1,y1,x2,y2,layer)
  local ax,ay,a=M.flowSample(s,f,x1,y1,layer)
  local bx,by,b=M.flowSample(s,f,x2,y2,layer)
  if a+b<0.003 then return end
  local dx,dy=bx-ax,by-ay
  local length=math.max(0.001,math.sqrt(dx*dx+dy*dy))
  local nx,ny=-dy/length*0.55,dx/length*0.55
  local c=f.lethal and {0.55,0.32,0.85} or {0.15,0.55,0.70}
  local function v(x,y,alpha)return {x,y,0,0,c[1],c[2],c[3],alpha}end
  local p1,p2,p3,p4=v(ax+nx,ay+ny,a),v(ax-nx,ay-ny,a),v(bx+nx,by+ny,b),v(bx-nx,by-ny,b)
  for _,p in ipairs({p1,p2,p3,p3,p2,p4})do vertices[#vertices+1]=p end
 end
 for _,f in ipairs(M.fields(s)) do
  local left,right=math.floor((f.x-260)/40)*40,math.ceil((f.x+260)/40)*40
  local top,bottom=math.floor((f.y-260)/40)*40,math.ceil((f.y+260)/40)*40
  for layer=0,2 do
   for x=left,right,40 do
    for y=top,bottom-20,20 do segment(f,x,y,x,y+20,layer) end
   end
   for y=top,bottom,40 do
    for x=left,right-20,20 do segment(f,x,y,x+20,y,layer) end
   end
  end
 end
 if #vertices==0 then return end
 if not flowMesh or #vertices>flowCapacity then
  if flowMesh then flowMesh:release() end
  flowCapacity=math.max(32768,#vertices)
  flowMesh=G.newMesh(flowCapacity,'triangles','stream')
 end
 flowMesh:setVertices(vertices);flowMesh:setDrawRange(1,#vertices)
 G.setColor(1,1,1);G.draw(flowMesh)
end
local function crossed(ax,ay,bx,by,x,y,r)
 local dx,dy=bx-ax,by-ay
 local t=math.max(0,math.min(1,((x-ax)*dx+(y-ay)*dy)/math.max(0.0001,dx*dx+dy*dy)))
 return (ax+dx*t-x)^2+(ay+dy*t-y)^2<r*r
end
function M.step(s,dt)
 local fields,portals=M.fields(s),M.portals(s)
 for _,list in ipairs({s.players,s.enemies,s.pickups,s.shots,s.hostile}) do
  local projectile=list==s.shots or list==s.hostile
  for _,v in ipairs(list) do
   if not v.dead and (not v.hp or v.hp>0) then
    local ax,ay=M.force(s,v.x,v.y)
    if projectile then v.vx,v.vy=v.vx+ax*dt,v.vy+ay*dt
    else
     local damping=math.exp(-2.5*dt)
     v.gravityX=((v.gravityX or 0)+ax*dt)*damping
     v.gravityY=((v.gravityY or 0)+ay*dt)*damping
     v.x=math.max(18,math.min(s.width-18,v.x+v.gravityX*dt))
     v.y=math.max(18,math.min(s.height-18,v.y+v.gravityY*dt))
    end
    local px,py=v.spaceX or v.x,v.spaceY or v.y
    v.portalCooldown=math.max(0,(v.portalCooldown or 0)-dt)
    if s.time>=3 and v.portalCooldown==0 then
     for i,p in ipairs(portals) do
      if crossed(px,py,v.x,v.y,p.x,p.y,p.r) then
       local other=portals[3-i]
       local dx,dy=(s.width/2-other.x),(s.height/2-other.y)
       local d=math.sqrt(dx*dx+dy*dy)
       v.x,v.y=other.x+dx/d*40,other.y+dy/d*40
       v.portalCooldown=0.8
       px,py=v.x,v.y
       if #s.rings<40 then s.rings[#s.rings+1]={x=v.x,y=v.y,r=55,ttl=0.35,color={0.3,0.8,1}} end
       break
      end
     end
    end
    if s.wave>=5 and (s.wave>5 or s.waveClock>=3) then
     for _,f in ipairs(fields) do
      if f.lethal and crossed(px,py,v.x,v.y,f.x,f.y,f.r) then
       if list==s.players then
        v.hp=0;v.downTime=0;v.revive=0;v.gravityX=0;v.gravityY=0
        -- Leave a rescuable marker outside the lethal core.
        v.x,v.y=f.x-95,f.y;v.spaceX,v.spaceY=v.x,v.y
        s.sfx.hurt=(s.sfx.hurt or 0)+1;s.shake=5
       elseif list==s.enemies then v.dead=true
       else v.ttl=0 end
      end
     end
    end
    v.spaceX,v.spaceY=v.x,v.y
   end
  end
  if projectile or list==s.pickups then
   for i=#list,1,-1 do if list[i].ttl<=0 then table.remove(list,i) end end
  end
 end
end
function M.draw(s,G)
 local strength=M.strength(s)
 for _,f in ipairs(M.fields(s)) do
  G.setColor(0.4,0.35,1,0.12+strength*0.2);G.setLineWidth(2)
  for i=1,3 do G.circle('line',f.x,f.y,f.r+9*i+math.sin(s.time*2+i)*3) end
  G.setColor(f.lethal and 1 or 0.3,f.lethal and 0.4 or 0.8,1,0.5+0.5*strength)
  G.setLineWidth(3);G.circle('line',f.x,f.y,f.r+3)
  G.setColor(0.005,0.008,0.02);G.circle('fill',f.x,f.y,f.r)
  if f.lethal then
   for i=1,12 do
    local a=i*math.pi/6+s.time*0.9
    G.setColor(1,0.5,0.8,0.7);G.line(f.x+math.cos(a)*34,f.y+math.sin(a)*34,f.x+math.cos(a+0.2)*46,f.y+math.sin(a+0.2)*46)
   end
  end
 end
 for i,p in ipairs(M.portals(s)) do
  G.setColor(i==1 and 0.2 or 0.9,0.8,1,0.8);G.setLineWidth(3)
  for j=1,3 do G.arc('line','open',p.x,p.y,p.r+j*4,s.time*(i==1 and 2 or -2)+j*2,s.time*(i==1 and 2 or -2)+j*2+1.4) end
 end
 G.setLineWidth(1)
end
return M
