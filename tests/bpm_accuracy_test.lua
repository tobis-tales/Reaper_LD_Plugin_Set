-- Accuracy test for the Live BPM Analyzer DSP core.
-- Generates synthetic songs at known tempos and measures the estimation error.

BPM_ANALYZER_TEST = {}
dofile(((arg[0]:match("(.*/)") or "./").."../").."Live BPM Analyzer.lua")

local T = BPM_ANALYZER_TEST
local SR = T.sample_rate

math.randomseed(12345)

-- Synthetic song: kick on every beat, hat on offbeats, snare on 2 and 4,
-- plus low-level noise. Mono, 1-indexed table.
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
    -- kick with slight human jitter (+-3 ms)
    local jitter = (math.random() - 0.5) * 0.006
    add_burst(t0 + jitter, 60, 0.05, 0.9)
    -- snare on beats 2 and 4 of each bar
    if beat % 4 == 1 or beat % 4 == 3 then
      add_burst(t0 + jitter, 200, 0.04, 0.5)
    end
    -- offbeat hat
    add_burst(t0 + beat_period / 2 + jitter, 3000, 0.01, 0.25)
    beat = beat + 1
  end

  return buf, n
end

local function run_case(bpm, seconds)
  local buf, n = make_song(bpm, seconds)
  local onsets = T.build_onset_envelope(buf, n, 1)
  if not onsets then
    return nil, nil, "no envelope"
  end
  local est, conf = T.estimate_bpm(onsets)
  if not est then
    return nil, nil, "no estimate"
  end
  return est, conf, nil
end

local cases = {
  { bpm = 130.0, seconds = 24 },
  { bpm = 130.0, seconds = 60 },
  { bpm = 130.0, seconds = 120 },
  { bpm = 87.5,  seconds = 60 },
  { bpm = 95.3,  seconds = 60 },
  { bpm = 122.3, seconds = 120 },
  { bpm = 174.0, seconds = 60 },
  { bpm = 68.0,  seconds = 120 },
  { bpm = 140.0, seconds = 24 },
  { bpm = 128.0, seconds = 120 },
}

local failures = 0
print(string.format("%-10s %-8s %-10s %-8s %-8s %s", "actual", "span", "estimated", "error", "conf", "verdict"))

for _, case in ipairs(cases) do
  local started = os.clock()
  local est, conf, err = run_case(case.bpm, case.seconds)
  local elapsed = os.clock() - started

  if err then
    print(string.format("%-10.2f %-8d FAILED: %s", case.bpm, case.seconds, err))
    failures = failures + 1
  else
    -- allow half/double octave (user has Half/Double buttons for that)
    local candidates = { est, est * 2, est / 2 }
    local best_err = math.huge
    local best_est = est
    for _, c in ipairs(candidates) do
      local e = math.abs(c - case.bpm)
      if e < best_err then best_err = e; best_est = c end
    end
    local octave_note = (best_est ~= est) and " (octave)" or ""
    local limit = (case.seconds >= 60) and 0.10 or 0.30
    local ok = best_err <= limit
    if not ok then failures = failures + 1 end
    print(string.format("%-10.2f %-8d %-10.3f %-8.3f %-8.2f %s%s  [%.1fs]",
      case.bpm, case.seconds, est, best_err, conf, ok and "PASS" or "FAIL", octave_note, elapsed))
  end
end

print(failures == 0 and "\nALL PASS" or ("\nFAILURES: " .. failures))
os.exit(failures == 0 and 0 or 1)
