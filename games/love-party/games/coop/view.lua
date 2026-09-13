local Avatar=require("games.volley.avatar")
local T=require("games.coop.stack")
local B=require("games.coop.bubbles")
local V={}
local C={bg={.045,.065,.12},panel={.085,.115,.18},ink={.92,.94,.88},dim={.48,.56,.66},mint={.36,.9,.73},orange={1,.58,.36},gold={1,.81,.4}}
local blocks={{.34,.79,.91},{1,.81,.4},{.72,.50,.91},{.37,.86,.66},{.97,.44,.49},{.40,.56,.96},{1,.62,.33}}
local fonts={}
local function color(c,a) love.graphics.setColor(c[1],c[2],c[3],a or 1) end
local function box(c,x,y,w,h,r,a) color(c,a); love.graphics.rectangle("fill",x,y,w,h,r or 0) end
local function text(s,x,y,n,c,w,align)
  if not fonts[n] then fonts[n]=love.graphics.newFont(n) end
  love.graphics.setFont(fonts[n]); color(c or C.ink)
  if w then love.graphics.printf(s,x,y,w,align or "left") else love.graphics.print(s,x,y) end
end
local function circle(c,x,y,r,a) color(c,a); love.graphics.circle("fill",x,y,r) end
local function portrait(p,x,y,size)
  local c=p.slot%2==1 and C.orange or C.mint
  box(c,x,y,size,size,10)
  if p.image==nil or p.renderedAvatar~=p.avatar then p.image=Avatar.image(p.avatar) or false; p.renderedAvatar=p.avatar end
  if p.image then
    local w,h=p.image:getDimensions(); local s=(size-8)/math.max(w,h)
    love.graphics.setColor(1,1,1); love.graphics.draw(p.image,x+(size-w*s)/2,y+(size-h*s)/2,0,s,s)
  else
    circle(C.bg,x+size*.32,y+size*.43,size*.06); circle(C.bg,x+size*.68,y+size*.43,size*.06)
    box(C.bg,x+size*.32,y+size*.69,size*.36,3)
  end
end
local function header(app)
  text("GAMENIGHT  /  CO-OP CLUB",48,28,12,C.mint)
  text(app.module.title,46,53,37,C.ink)
  text(app.module==T and "TWO MINDS. ONE STACK." or "SMALL BUBBLES. BIG PROBLEMS.",48,104,12,C.dim)
  box(C.panel,875,29,357,83,16)
  local g=app.game
  if app.module==T then
    text("SHARED ROWS",897,43,11,C.mint); text(g.rows.." / "..g.target,896,61,29,C.ink)
    text("CLEAR THE WHOLE WIDTH",1051,70,10,C.dim,157,"right")
  else
    text("WAVE "..g.wave.." / 5",895,44,12,C.mint)
    text(math.ceil(g.clock).."s",1110,52,31,C.ink,100,"right")
    for i=1,6 do circle(i<=g.hearts and C.orange or C.dim,903+(i-1)*24,83,7,i<=g.hearts and 1 or .25) end
  end
end
local function cell(kind,x,y,a)
  local c=blocks[kind]
  box(c,x+1,y+1,24,24,4,a)
  if not a or a>.5 then box(C.ink,x+4,y+4,18,3,1,.22) end
end
function V.stack(app)
  local g=app.game; local ox,oy=484,177
  box(C.panel,ox-12,oy-12,336,493,14)
  for y=1,18 do for x=1,12 do
    box(C.bg,ox+(x-1)*26,oy+(y-1)*26,25,25,3)
    if g.board[y][x] then cell(g.board[y][x],ox+(x-1)*26,oy+(y-1)*26) end
  end end
  box(C.mint,ox+155,oy,2,468,0,.5)
  for i,p in ipairs(g.players) do
    local ghost=T.dropY(g,p,p.x,p.rot)
    if ghost then for _,v in ipairs(T.cells(p.kind,p.rot)) do cell(p.kind,ox+(p.x+v[1]-1)*26,oy+(ghost+v[2]-1)*26,.19) end end
    for _,v in ipairs(T.cells(p.kind,p.rot)) do
      local y=p.y+v[2]
      if y>=1 and y<=18 then cell(p.kind,ox+(p.x+v[1]-1)*26,oy+(y-1)*26) end
    end
    local x=i==1 and 64 or 862; local c=i==1 and C.orange or C.mint
    box(C.panel,x,178,350,198,16)
    portrait(p,x+23,200,60)
    text(p.name or ("P"..p.slot),x+102,202,23,c,226)
    text(p.bot and "CPU TEAMMATE" or ("PLAYER "..p.slot),x+103,238,11,C.dim)
    text("UP NEXT",x+24,296,11,C.dim)
    for _,v in ipairs(T.cells(p.next,0)) do cell(p.next,x+178+v[1]*26,282+v[2]*26) end
    text(i==1 and "YOU BUILD THIS HALF  >" or "<  YOU BUILD THIS HALF",x,404,14,c,350,"center")
    text("Complete rows together.\nYour half waits for theirs.",x+18,459,20,C.ink,318)
    text("Move sideways\nRotate to fill the gaps\nDrop when you're ready",x+18,542,15,C.dim,318)
  end
  if g.flash>0 then box(C.mint,ox-12,oy-12,336,493,14,g.flash*.2) end
  text("ONE FULL ROW = BOTH HALVES",400,676,13,C.mint,480,"center")
  local legends={"P1 A D / W ROTATE / S SOFT DROP / SPACE DROP","P2 ARROWS / UP ROTATE / DOWN SOFT DROP / ENTER DROP",
    "P3 J L / I ROTATE / K SOFT DROP / U DROP","P4 NUMPAD 4 6 / 8 ROTATE / 5 SOFT DROP / 0 DROP"}
  for i,p in ipairs(g.players) do text(legends[p.slot],48,734+(i-1)*24,12,C.dim) end
  text("PAD  D-PAD / A ROTATE / B DROP",850,734,12,C.ink,382,"right")
end
function V.bubbles(app)
  local g=app.game
  box(C.panel,48,162,1184,515,20)
  for i=1,12 do
    local x=80+(i*197)%1110; local y=206+(i*113)%380
    circle(C.mint,x,y,3,.1)
  end
  for _,r in ipairs(B.obstacles(g)) do box(C.gold,r.x,r.y,r.w,r.h,5) end
  box(C.mint,64,B.floor,1152,4,2)
  for _,r in ipairs(g.ropes) do
    box(C.gold,r.x-2,r.y,4,B.floor-r.y,2)
    color(C.gold); love.graphics.polygon("fill",r.x,r.y-9,r.x-8,r.y+4,r.x+8,r.y+4)
  end
  for _,b in ipairs(g.bubbles) do
    local c=blocks[b.size==3 and 3 or b.size==2 and 1 or 4]
    circle(c,b.x,b.y,b.r,.17)
    color(c); love.graphics.setLineWidth(3); love.graphics.circle("line",b.x,b.y,b.r)
    circle(C.ink,b.x-b.r*.3,b.y-b.r*.35,b.r*.14,.65)
    text(tostring(b.size),b.x-20,b.y-10,16,c,40,"center")
  end
  for _,p in ipairs(g.players) do
    if p.out>0 then
      text("BACK IN "..string.format("%.1f",p.out),p.x-65,590,10,C.dim,130,"center")
    elseif p.invuln<=0 or math.floor(g.time*10)%2==0 then
      portrait(p,p.x-23,B.floor-49,46)
      text(p.name or "CPU",p.x-70,B.floor-75,11,C.ink,140,"center")
    end
  end
  if g.phase=="ready" or g.phase=="clear" then
    box(C.bg,400,306,480,108,18,.95)
    text(g.phase=="clear" and "CLEAN SWEEP!" or ("WAVE "..g.wave),400,326,32,C.mint,480,"center")
    text(g.phase=="clear" and "+1 TEAM HEART NEXT WAVE" or "STAY TOGETHER. SHOOT UP.",400,379,11,C.dim,480,"center")
  end
  if g.flash>0 then box(C.orange,48,162,1184,515,20,g.flash*.5) end
  text("BIG BUBBLES SPLIT. SMALL BUBBLES POP. YOUR HEARTS ARE SHARED.",48,697,13,C.mint)
  text("P1 A D + SPACE    P2 ARROWS + ENTER    P3 J L + I    P4 NUMPAD 4 6 + 8",48,741,12,C.dim)
  text("PAD  STICK + A TO FIRE",918,741,12,C.ink,314,"right")
end
function V.draw(app)
  box(C.bg,0,0,1280,800)
  header(app)
  if app.module==T then V.stack(app) else V.bubbles(app) end
  text(app.managed and "BACK  PARTY" or "ESC / START  PAUSE     F11 FULLSCREEN     M SOUND",600,772,10,C.dim,630,"right")
  if app.screen=="menu" then
    box(C.bg,0,0,1280,800)
    text("G A M E N I G H T   /   T H E   C O - O P   C O L L E C T I O N",64,61,12,C.mint)
    text("BETTER",59,111,77,C.ink); text("TOGETHER.",59,192,77,C.orange)
    text("Two proven recipes.\nOne very cooperative couch.",64,311,25,C.ink)
    text("Share the wins. Share the disasters.",64,409,17,C.dim)
    local names={"STACK TOGETHER","BUBBLE BUDDIES"}
    local desc={"A shared falling-block puzzle.\nBuild your half. Clear rows together.","Pop, split, dodge, repeat.\nFive waves. One shared pool of hearts."}
    for i=1,2 do
      local y=143+(i-1)*192
      box(app.choice==i and {.13,.22,.25} or C.panel,680,y,528,161,16)
      text("0"..i.."  /  "..(i==1 and "CO-OP PUZZLE" or "CO-OP ARCADE"),703,y+20,11,C.mint)
      text(names[i],703,y+47,25,app.choice==i and C.gold or C.ink)
      text(desc[i],703,y+94,16,C.dim)
    end
    box(C.panel,64,506,510,100,14)
    text("THE CREW",86,524,11,C.mint)
    text(app.crew==1 and "YOU + CPU TEAMMATE" or app.crew==2 and "TWO HUMAN PLAYERS" or "FOUR HUMAN PLAYERS",86,548,21,C.ink)
    text("LEFT / RIGHT TO CHANGE",86,582,10,C.dim)
    local pads=0; for i=1,4 do if app.pads[i] and app.pads[i]:isConnected() then pads=pads+1 end end
    text(pads.." CONTROLLERS CONNECTED",64,645,12,C.dim)
    text("UP / DOWN  CHOOSE GAME",703,563,13,C.dim)
    text("ENTER / A  LET'S PLAY",703,611,24,C.mint)
    text("Drawn profile faces join you when launched through GameNight.",64,744,13,C.dim)
  elseif app.screen=="paused" or app.game.phase=="won" or app.game.phase=="lost" then
    box(C.bg,48,162,1184,515,20,.95)
    local phase=app.game.phase
    text(phase=="won" and "YOU DID IT. TOGETHER." or phase=="lost" and "ONE MORE TRY?" or "TAKE A BREATHER",130,290,44,phase=="won" and C.mint or C.gold,1020,"center")
    text(phase=="lost" and (app.game.reason or "YOUR STACK REACHED THE TOP") or "Good teamwork deserves a moment.",180,370,19,C.dim,920,"center")
    text(app.managed and "BACK TO RETURN TO THE PARTY" or app.screen=="paused" and "ESC / START RESUME     Q / B MENU" or "ENTER / A REMATCH     ESC / B MENU",180,451,16,C.ink,920,"center")
  end
end
return V
