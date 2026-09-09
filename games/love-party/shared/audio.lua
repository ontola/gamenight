local A = { enabled = true, sources = {}, last = {} }
function A.load()
	if not love.sound or not love.audio then
		return
	end
	for name, frequency in pairs({
		point = 740,
		hit = 160,
		finish = 980,
		blast = 90,
		shot = 1100,
		burst = 120,
		hurt = 65,
		pickup = 880,
		pulse = 180,
	}) do
		local rate, count = 22050, 3308
		local data = love.sound.newSoundData(count, rate, 16, 1)
		for i = 0, count - 1 do
			local envelope = (1 - i / count) ^ 2
			data:setSample(i, math.sin(i / rate * frequency * math.pi * 2 * (1 - i / count * 0.65)) * envelope * 0.12)
		end
		A.sources[name] = love.audio.newSource(data, "static")
	end
end
function A.play(name)
	local source = A.sources[name]
	local now = love.timer and love.timer.getTime() or 0
	if A.last[name] and now - A.last[name] < (name == "shot" and 0.07 or 0.045) then
		return
	end
	if A.enabled and source then
		A.last[name] = now
		source:stop()
		source:play()
	end
end
function A.mute()
	A.enabled = false
	for _, source in pairs(A.sources) do
		source:stop()
	end
end
return A
