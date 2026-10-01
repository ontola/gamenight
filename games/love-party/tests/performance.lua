-- Run from games/love-party: luajit tests/performance.lua
love={graphics={getRendererInfo=function()return 'OpenGL','4','vendor','Test GPU' end,
    getPixelDimensions=function()return 1920,1080 end},system={getOS=function()return 'Test OS' end}}
local Performance=require('shared.performance')
local reports={}
local bridge={phase='ready',session='one',transport={send=function(_,m)
    local copy={};for k,v in pairs(m.sample) do copy[k]=v end
    reports[#reports+1]={session=m.session,sample=copy}
end}}
local p=Performance.new()
for _=1,20 do p:update(1,bridge) end
assert(#reports==0)
bridge.phase='running';p:update(1,bridge)
for _=1,10 do p:update(1,bridge) end
assert(#reports==1 and reports[1].sample.frames==10 and reports[1].sample.elapsed_us==10000000)
assert(reports[1].sample.gpu=='Test GPU' and reports[1].sample.cpu==nil)
bridge.phase='paused';for _=1,20 do p:update(1,bridge) end
bridge.phase='running';p:update(1,bridge);p:update(600,bridge)
assert(p.sample.frames==10)
for _=1,10 do p:update(1,bridge) end
assert(#reports==2 and reports[2].sample.frames==20)
bridge.session='two';p:update(1,bridge)
for _=1,10 do p:update(1,bridge) end
assert(#reports==3 and reports[3].session=='two' and reports[3].sample.frames==10)
assert(reports[3].sample.width==1920 and reports[3].sample.slow_frames==10)
print('PASS performance cadence, pause, suspension, session reset and hardware coverage')
