-- Timing harness for the Live BPM Analyzer DSP core. NOT a *_test file on
-- purpose: it measures, it does not judge, so it must not run in the suite.
--
-- Why it exists: the live loop calls analyze_now() synchronously in the UI
-- thread every 0.75 s. If one pass costs more than a few milliseconds the
-- playback cursor visibly stutters. This prints the cost per stage so the
-- "before" and "after" of that work are numbers, not impressions.
--
--   lua tests/bpm_timing.lua [seconds] [bpm] [repeats]

BPM_ANALYZER_TEST = {}
dofile(((arg[0]:match("(.*/)") or "./").."../").."Live BPM Analyzer.lua")

local T = BPM_ANALYZER_TEST
local SR = T.sample_rate
local HOP = T.hop_size

local SECONDS = tonumber(arg[1]) or 24
local BPM = tonumber(arg[2]) or 128
local REPEATS = tonumber(arg[3]) or 5

math.randomseed(12345)

-- Same synthetic song as bpm_accuracy_test.lua: kick on every beat, snare on
-- 2 and 4, offbeat hat, low-level noise, +-3 ms jitter.
local function make_song(bpm, seconds)
  local n = math.floor(seconds * SR)
  local buf = {}
  for i = 1, n do
    buf[i] = (math.random() - 0.5) * 0.02
  end

  local beat_period = 60 / bpm

  local function add_burst(time_pos, freq, decay, amp)
    local start = math.floor(time_pos * SR) + 1
    local length = math.floor(decay * 6 * SR)
    for j = 0, length do
      local idx = start + j
      if idx >= 1 and idx <= n then
        local t = j / SR
        buf[idx] = buf[idx] + amp * math.exp(-t / decay) * math.sin(2 * math.pi * freq * t)
      end
    end
  end

  local beat = 0
  while true do
    local t0 = beat * beat_period
    if t0 >= seconds then break end
    local jitter = (math.random() - 0.5) * 0.006
    add_burst(t0 + jitter, 60, 0.05, 0.9)
    if beat % 4 == 1 or beat % 4 == 3 then
      add_burst(t0 + jitter, 200, 0.04, 0.5)
    end
    add_burst(t0 + beat_period / 2 + jitter, 3000, 0.01, 0.25)
    beat = beat + 1
  end

  return buf, n
end

local function median(values)
  local copy = {}
  for i, v in ipairs(values) do copy[i] = v end
  table.sort(copy)
  local middle = math.floor((#copy + 1) / 2)
  if #copy % 2 == 1 then return copy[middle] end
  return (copy[middle] + copy[middle + 1]) / 2
end

-- Run `body` REPEATS times, return the median wall time in ms and the last result.
local function timed(body)
  local samples = {}
  local result
  for _ = 1, REPEATS do
    local started = os.clock()
    result = body()
    samples[#samples + 1] = (os.clock() - started) * 1000
  end
  return median(samples), result
end

local buf, n = make_song(BPM, SECONDS)

print(string.format(
  "Live BPM Analyzer -- stage timings\n%d s of synthetic audio at %.1f BPM, %d Hz, %d repeats, median ms\n",
  SECONDS, BPM, SR, REPEATS))

local envelope_ms, onsets = timed(function()
  return T.build_onset_envelope(buf, n, 1)
end)

if not onsets then
  print("no envelope -- nothing to measure")
  os.exit(1)
end

local decimate_ms, coarse = timed(function()
  return T.decimate_envelope(onsets)
end)

-- The coarse comb sweep exactly as estimate_bpm runs it: 0.5 BPM grid from 60
-- to 200 on the 2x-decimated envelope, each score multiplied by the prior.
local frame_rate = SR / HOP
local coarse_rate = frame_rate / 2
local comb_ms = timed(function()
  local best = 0
  local bpm = 60
  while bpm <= 200 do
    local score = T.comb_score(coarse, coarse_rate, bpm) * T.tempo_prior(bpm)
    if score > best then best = score end
    bpm = bpm + 0.5
  end
  return best
end)

-- What the live loop actually does per update once the window is rolling: turn
-- one UPDATE_INTERVAL of new audio into frame energies, then run the cheap
-- passes over the whole rolling buffer.
local chunk_samples = math.floor(0.75 * SR) + T.frame_size
local chunk = {}
for i = 1, chunk_samples do chunk[i] = buf[i] end

local chunk_ms = timed(function()
  local out = {}
  T.energies_for_samples(chunk, chunk_samples, 1, out)
  return out
end)

local rolling = {}
T.energies_for_samples(buf, n, 1, rolling)

local passes_ms = timed(function()
  return T.envelope_from_energies(rolling)
end)

local estimate_ms, estimated = timed(function()
  return T.estimate_bpm(onsets)
end)

-- What is left of estimate_bpm once decimate and the comb sweep are accounted
-- for: the two-stage long-lag refinement plus the confidence bookkeeping.
local refine_ms = estimate_ms - decimate_ms - comb_ms

print(string.format("%-26s %10s", "stage", "median ms"))
print(string.format("%-26s %10.1f", "build_onset_envelope", envelope_ms))
print(string.format("%-26s %10.1f", "  energies, 0.75 s chunk", chunk_ms))
print(string.format("%-26s %10.1f", "  envelope_from_energies", passes_ms))
print(string.format("%-26s %10.1f", "decimate_envelope", decimate_ms))
print(string.format("%-26s %10.1f", "comb sweep (60-200)", comb_ms))
print(string.format("%-26s %10.1f", "refine + confidence", refine_ms))
print(string.format("%-26s %10.1f", "estimate_bpm (total)", estimate_ms))
print(string.rep("-", 37))
print(string.format("%-26s %10.1f", "batch pass (button)", envelope_ms + estimate_ms))
print(string.format("%-26s %10.1f", "live update, envelope only", chunk_ms + passes_ms))
print(string.format("\nframes: %d   estimated: %.3f BPM", #onsets, estimated or 0))
print(string.format("live loop budget is one defer frame; the loop calls this every %.2f s", 0.75))
