-- Short synthesized arcade cues; no external audio assets.
local A={enabled=true,sources={}}
function A.load()
  if not love.sound or not love.audio then return end
  local defs={hit={370,.085},spike={175,.14},swing={310,.045},smash={125,.19},jump={230,.055},point={610,.26},explode={70,.3},serve={520,.12},win={780,.45},lava={110,.16},reform={440,.15}}
  for name,d in pairs(defs) do
    local count=math.floor(22050*d[2])
    local data=love.sound.newSoundData(count,22050,16,1)
    for i=0,count-1 do
      local t=i/22050; local envelope=(1-i/count)^2
      local phase=2*math.pi*(d[1]*t+(name=="jump" and 1500 or -120)*t*t)
      local wave=math.sin(phase)*.6+math.sin(phase*2)*.18
      if name=="explode" or name=="lava" then wave=wave*.4+(love.math.random()*2-1)*.5 end
      data:setSample(i,wave*envelope*.3)
    end
    A.sources[name]=love.audio.newSource(data,"static")
  end
end
function A.play(name)
  if A.enabled and A.sources[name] then A.sources[name]:stop(); A.sources[name]:play() end
end
function A.stop() love.audio.stop() end
return A
