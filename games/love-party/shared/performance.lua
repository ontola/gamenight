-- Neutral, session-scoped application-frame diagnostics. No cloud or identities.
local Performance={}; Performance.__index=Performance
function Performance.new()
    -- Protocol tests can run with the graphics module disabled. Those update
    -- ticks are not rendered frames and must not become performance samples.
    local graphics=love.graphics
    local gpu
    if graphics then gpu=select(4,graphics.getRendererInfo()) end
    return setmetatable({graphics=graphics,sent=0,sample={frames=0,elapsed_us=0,slow_frames=0,max_frame_us=0,
        gpu=(gpu or ''):sub(1,128),os=love.system.getOS()}},Performance)
end
function Performance:update(dt,bridge)
    if not self.graphics then return end
    local wasRunning=self.running
    self.running=bridge.phase=='running' and bridge.session~=nil
    if not self.running then return end
    if self.session~=bridge.session then
        self.session=bridge.session;self.sent=0
        self.sample.frames,self.sample.elapsed_us,self.sample.slow_frames,self.sample.max_frame_us=0,0,0,0
        return
    end
    if not wasRunning or dt<=0 or dt>2 then return end
    local s=self.sample;local us=math.floor(dt*1000000+.5)
    s.frames=s.frames+1;s.elapsed_us=s.elapsed_us+us;s.slow_frames=s.slow_frames+(us>33333 and 1 or 0);s.max_frame_us=math.max(s.max_frame_us,us)
    if s.elapsed_us-self.sent>=10000000 then
        s.width,s.height=self.graphics.getPixelDimensions()
        bridge.transport:send({type='performance',session=bridge.session,sample=s})
        self.sent=s.elapsed_us
    end
end
return Performance
