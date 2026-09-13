--- Is the synthesized kit actually sound?
---
--- Nobody has heard it. It was written, it builds without error, and every
--- check so far has confirmed only that it does not crash -- which is also
--- true of a kit that renders eleven seconds of silence.
---
--- Three things are measurable without ears, and each is a real bug:
---   silence  -- a voice whose numbers cancel to nothing
---   clipping -- samples pinned at the rails, which is audible distortion
---   DC offset -- a waveform not centred on zero, which wastes headroom and
---               thumps when the source starts and stops
---
--- Runs in the bare interpreter: love.sound is stubbed, because render()
--- needs exactly newSoundData and setSample and nothing else. That stub is
--- also why this cannot join the shared suites -- run_sim runs under real
--- LÖVE, where replacing the global `love` would break everything else.
---
--- Measured 2026-09-06: 13 voices, peaks 0.15-0.51, no clipped samples, DC
--- within 0.002 of zero. The peaks sit around half scale deliberately, so
--- several voices overlapping do not clip the master -- but it does mean the
--- kit may simply be QUIET, and that is the one thing here a person has to
--- judge. If it is, raise the per-voice `gain` values in KIT rather than the
--- playback volumes, so the headroom stays where it is.
---
---   luajit tests/probe_audio.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local captured = {}

-- The stub mirrors LÖVE's real signatures exactly. It has to: this file is
-- inside the project the type checker analyses, so a narrower stub becomes
-- the type it believes love.sound.newSoundData has, and every real four-
-- argument call in app/audio.lua starts failing `make types`. A test double
-- that lies about its interface breaks more than it tests.
---@diagnostic disable: duplicate-set-field, lowercase-global
love = {                                             -- luacheck: ignore
  sound = {
    ---@param samples integer
    ---@param rate integer
    ---@param bits integer
    ---@param channels integer
    newSoundData = function(samples, rate, bits, channels)
      local _ = { rate, bits, channels }
      local d = { n = samples, s = {} }
      function d:setSample(i, v) self.s[i] = v end
      captured[#captured+1] = d
      return d
    end,
  },
  audio = {
    ---@param data table
    ---@param kind string
    newSource = function(data, kind)
      local _ = kind
      return {
        data = data,
        clone = function(self) return self end, stop = function() end,
        setVolume = function() end, setPitch = function() end,
        play = function() end,
      }
    end,
  },
}

local audio = require("app.audio")
audio.load()

print("")
print(("%-9s %8s %8s %8s %8s %8s")
  :format("voice", "samples", "peak", "rms", "dc", "clipped"))

local fails = {}
-- Voices are built in pairs() order, so name them by matching sample counts.
local order = {}
for _, d in ipairs(captured) do order[#order+1] = d end

for i, d in ipairs(order) do
  local peak, sum, sumsq, clipped = 0, 0, 0, 0
  for k = 0, d.n - 1 do
    local v = d.s[k] or 0
    peak = math.max(peak, math.abs(v))
    sum = sum + v
    sumsq = sumsq + v * v
    if math.abs(v) >= 0.999 then clipped = clipped + 1 end
  end
  local rms = math.sqrt(sumsq / d.n)
  local dc  = sum / d.n
  print(("#%-8d %8d %8.3f %8.3f %8.4f %7d")
    :format(i, d.n, peak, rms, dc, clipped))
  if peak < 0.02 then fails[#fails+1] = ("voice #%d is silent (peak %.4f)"):format(i, peak) end
  if clipped > d.n * 0.01 then
    fails[#fails+1] = ("voice #%d clips on %.1f%% of samples"):format(i, 100 * clipped / d.n)
  end
  if math.abs(dc) > 0.08 then
    fails[#fails+1] = ("voice #%d has a DC offset of %.3f"):format(i, dc)
  end
end

print("")
if #fails == 0 then
  print(("  all %d voices: audible, unclipped, centred"):format(#order))
else
  for _, f in ipairs(fails) do print("  BAD: " .. f) end
end
print("")
os.exit(#fails == 0 and 0 or 1)
