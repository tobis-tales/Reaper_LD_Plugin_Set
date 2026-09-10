-- The live BPM window is now read incrementally: each update pulls only the
-- audio that is new, turns it into frame energies and appends them to a rolling
-- buffer. That is only allowed if it produces the SAME envelope the old batch
-- read produced over the same span -- otherwise the accuracy guardrails in
-- AGENTS.md ("4. Live BPM Analyzer") are gone and nobody notices.
--
-- So this drives the real read_live_envelope through a fake REAPER: a fake
-- audio accessor over a synthetic song, a play cursor that advances in
-- UPDATE_INTERVAL steps, and a jump backwards. What comes out is compared
-- against build_onset_envelope over exactly the same samples.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

-- ---------------------------------------------------------------- fake REAPER

local song = {}
local song_length = 0

local state = {
  playing = true,
  play_pos = 0,
  cursor_pos = 0,
  item_start = 0,
  item_length = 0,
  accessors_created = 0,
  accessors_destroyed = 0,
  reads = {},          -- {start_sample=, sample_count=} per accessor read
}

local SR = 11025  -- checked against the hook's sample_rate once the script loads

local function fake_array(size)
  local array = { clear = function() end }
  array.size = size
  return array
end

reaper = {
  time_precise = function() return os.clock() end,

  GetMediaItemInfo_Value = function(_, key)
    if key == "D_POSITION" then return state.item_start end
    if key == "D_LENGTH" then return state.item_length end
    return 0
  end,

  GetPlayState = function() return state.playing and 1 or 0 end,
  GetPlayPosition = function() return state.play_pos end,
  GetCursorPosition = function() return state.cursor_pos end,

  GetMediaItemTake_Source = function(take) return { take = take } end,
  GetMediaSourceNumChannels = function() return 1 end,

  CreateTakeAudioAccessor = function(take)
    state.accessors_created = state.accessors_created + 1
    return { take = take }
  end,

  DestroyAudioAccessor = function()
    state.accessors_destroyed = state.accessors_destroyed + 1
  end,

  -- Reads from the song by time, the way the real accessor does. Samples past
  -- the end of the song read as silence.
  GetAudioAccessorSamples = function(_, sample_rate, channels, start_seconds, sample_count, buffer)
    local start_sample = math.floor((start_seconds * sample_rate) + 0.5)
    state.reads[#state.reads + 1] = { start_sample = start_sample, sample_count = sample_count }

    for index = 0, sample_count - 1 do
      buffer[(index * channels) + 1] = song[start_sample + index + 1] or 0
    end

    return 1
  end,

  new_array = fake_array,
}

-- ------------------------------------------------------------------ the plugin

BPM_ANALYZER_TEST = {}
dofile(folder .. "Live BPM Analyzer.lua")

local T = BPM_ANALYZER_TEST
SR = T.sample_rate
local HOP = T.hop_size
local FRAME = T.frame_size
local STEP = T.update_interval

local ITEM = "item"
local TAKE = "take"

-- ------------------------------------------------------------ synthetic audio

math.randomseed(12345)

-- Same material as bpm_accuracy_test.lua: kick on the beat, snare on 2 and 4,
-- offbeat hat, low-level noise, +-3 ms jitter.
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

-- --------------------------------------------------------------------- runner

local fails = 0
local function check(name, ok, note)
  if not ok then fails = fails + 1 end
  print(string.format("  %-5s %-46s %s", ok and "PASS" or "FAIL", name, note or ""))
end

local function load_song(bpm, seconds)
  song, song_length = make_song(bpm, seconds)
  state.item_start = 0
  state.item_length = seconds
  state.playing = true
  state.play_pos = 0
  state.cursor_pos = 0
  state.reads = {}
  T.release_accessor()
  T.set_window_seconds(24)
end

-- Advance the play cursor by one update interval and let the plugin read.
local function tick(seconds)
  state.play_pos = state.play_pos + (seconds or STEP)
  return T.read_live_envelope(ITEM, TAKE)
end

-- A plain 1-indexed mono buffer straight out of the song, for the batch pass.
local function slice(start_sample, sample_count)
  local buf = {}
  for index = 1, sample_count do
    buf[index] = song[start_sample + index] or 0
  end
  return buf
end

print("Live BPM Analyzer -- rolling window vs batch window:\n")

-- (a) --------------------------------------------------------- rolling==batch
do
  load_song(128, 60)

  local last_onsets
  local ticks = 0
  while state.play_pos + STEP <= 60 do
    last_onsets = tick()
    ticks = ticks + 1
  end

  local energies = T.reader.energies
  local max_frames = T.frames_for_seconds(24)

  check("(a) buffer trimmed to the 24 s window",
    #energies == max_frames,
    string.format("%d frames after %d updates, want %d", #energies, ticks, max_frames))

  -- The kept frames are the last max_frames on a grid whose next position is
  -- reader.next_frame_start, so the batch span starts exactly here.
  local first_sample = T.reader.next_frame_start - (max_frames * HOP)
  local span = ((max_frames - 1) * HOP) + FRAME
  local batch_buffer = slice(first_sample, span)

  local batch_energies = {}
  T.energies_for_samples(batch_buffer, span, 1, batch_energies)

  check("(a) batch pass over the same span, same frame count",
    #batch_energies == #energies,
    string.format("batch %d, rolling %d", #batch_energies, #energies))

  local worst = 0
  local worst_at = 0
  for index = 1, math.min(#batch_energies, #energies) do
    local diff = math.abs(batch_energies[index] - energies[index])
    if diff > worst then worst = diff; worst_at = index end
  end

  check("(a) every frame energy identical (1e-9)",
    #batch_energies == #energies and worst <= 1e-9,
    string.format("worst %.3e at frame %d", worst, worst_at))

  local rolling_bpm = T.estimate_bpm(T.envelope_from_energies(energies))
  local batch_bpm = T.estimate_bpm(T.build_onset_envelope(batch_buffer, span, 1))

  check("(a) same BPM out of both envelopes (0.001)",
    rolling_bpm and batch_bpm and math.abs(rolling_bpm - batch_bpm) <= 0.001,
    string.format("rolling %.4f, batch %.4f", rolling_bpm or 0, batch_bpm or 0))

  check("(a) one accessor for the whole run",
    state.accessors_created == 1,
    string.format("created %d, destroyed %d", state.accessors_created, state.accessors_destroyed))
end

-- (d) ------------------------------------------------------------- overlap
-- Every chunk has to start at the first sample of the next frame, which lies
-- up to FRAME_SIZE samples BEFORE the end of the previous chunk. Read the
-- chunks back to back instead and the frames straddling each boundary are
-- silently missing -- which is what test (a) above would then catch.
do
  load_song(128, 30)

  for _ = 1, 6 do tick() end

  local gaps = {}
  for index = 2, #state.reads do
    local previous = state.reads[index - 1]
    local previous_end = previous.start_sample + previous.sample_count
    gaps[#gaps + 1] = previous_end - state.reads[index].start_sample
  end

  local smallest = math.huge
  local largest = -math.huge
  for _, gap in ipairs(gaps) do
    if gap < smallest then smallest = gap end
    if gap > largest then largest = gap end
  end

  check("(d) chunks overlap by FRAME_SIZE-HOP_SIZE .. FRAME_SIZE-1",
    #gaps > 0 and smallest >= (FRAME - HOP) and largest < FRAME,
    string.format("%d chunks, overlap %d..%d samples", #state.reads, smallest, largest))
end

-- (b) ----------------------------------------------- stepper == synchronous
-- The sliced tempo search must return exactly what the straight loop returned.
-- "Roughly the same BPM" is not good enough here: the whole point of the
-- estimator is sub-0.01 BPM precision, and a stepper that resumes with slightly
-- different state would lose that quietly.
--
-- 174 BPM is in the list because it reads as half time and carries an octave
-- hint -- without it the octave comparison would be nil == nil and prove
-- nothing.
do
  local slowest_overall = 0
  local hints_seen = 0

  for _, case_bpm in ipairs({ 128, 174 }) do
    load_song(case_bpm, 24)

    local sample_count = math.floor(24 * SR)
    local buffer = slice(0, sample_count)
    local onsets = T.build_onset_envelope(buffer, sample_count, 1)

    local want_bpm, want_conf, want_octave, want_share = T.estimate_bpm(onsets)

    local estimator = T.start_estimate(onsets)
    local slices = {}
    local guard = 0
    local finished = false

    repeat
      local started = os.clock()
      finished = estimator.step(0.004)
      slices[#slices + 1] = (os.clock() - started) * 1000
      guard = guard + 1
    until finished or guard > 10000

    local slowest = 0
    for _, ms in ipairs(slices) do
      if ms > slowest then slowest = ms end
    end
    if slowest > slowest_overall then slowest_overall = slowest end
    if want_octave then hints_seen = hints_seen + 1 end

    local label = string.format("(b) %.0f BPM: ", case_bpm)

    check(label .. "same BPM, to the last bit",
      want_bpm and estimator.bpm and (estimator.bpm - want_bpm) == 0,
      string.format("sync %.6f, stepped %.6f", want_bpm or 0, estimator.bpm or 0))

    check(label .. "same confidence",
      ((estimator.confidence or 0) - (want_conf or 0)) == 0,
      string.format("sync %.6f, stepped %.6f", want_conf or 0, estimator.confidence or 0))

    check(label .. "same octave hint",
      estimator.octave_bpm == want_octave
        and ((estimator.octave_share or 0) - (want_share or 0)) == 0,
      string.format("sync %s @ %.4f, stepped %s @ %.4f",
        tostring(want_octave), want_share or 0,
        tostring(estimator.octave_bpm), estimator.octave_share or 0))

    check(label .. "the search really was sliced",
      #slices > 1,
      string.format("%d steps at a 4 ms budget", #slices))

    -- Not a comparison against estimate_bpm: that runs the same stepper, so a
    -- sweep that skipped half the grid would agree with itself. This anchors
    -- the grid itself -- 60 to 200 BPM in 0.5 steps, every candidate scored.
    local grid = estimator.candidates
    local expected = ((200 - 60) / 0.5) + 1
    local worst_gap = 0
    for index = 2, #grid do
      local gap = math.abs((grid[index].bpm - grid[index - 1].bpm) - 0.5)
      if gap > worst_gap then worst_gap = gap end
    end

    check(label .. "the whole 0.5 BPM grid was scored",
      #grid == expected
        and grid[1] and grid[1].bpm == 60
        and grid[#grid].bpm == 200
        and worst_gap < 1e-9,
      string.format("%d candidates (want %d), %s..%s", #grid, expected,
        grid[1] and tostring(grid[1].bpm) or "-",
        grid[#grid] and tostring(grid[#grid].bpm) or "-"))
  end

  check("(b) at least one case carried an octave hint",
    hints_seen > 0,
    string.format("%d of 2 cases", hints_seen))

  -- Timing is reported, not judged, below 50 ms: a slow machine must not turn
  -- the suite red over scheduling noise. Above that something is structurally
  -- wrong -- a slice that long is a stutter wherever it runs.
  check("(b) no slice ran away (< 50 ms)",
    slowest_overall < 50,
    string.format("slowest slice %.1f ms%s", slowest_overall,
      slowest_overall < 20 and "" or "  -- over 20 ms, worth a look"))
end

-- (c) --------------------------------------------------------------- resets
do
  load_song(128, 60)

  for _ = 1, 20 do tick() end
  local filled = #T.reader.energies
  local reads_before = #state.reads

  -- jump backwards
  state.play_pos = state.play_pos - 10
  T.read_live_envelope(ITEM, TAKE)

  check("(c) jump back empties the rolling buffer",
    #T.reader.energies == 0 and #state.reads == reads_before,
    string.format("%d frames before, %d after, no extra read", filled, #T.reader.energies))

  local rebuilt = 0
  for _ = 1, 8 do
    tick()
    rebuilt = #T.reader.energies
  end

  check("(c) and it builds up again from there",
    rebuilt > 0 and rebuilt < filled,
    string.format("%d frames after 8 updates", rebuilt))

  -- forward jump further than an update step
  local before_jump = #T.reader.energies
  state.play_pos = state.play_pos + (STEP * 4)
  T.read_live_envelope(ITEM, TAKE)

  check("(c) forward jump beyond one step resets too",
    #T.reader.energies == 0,
    string.format("%d frames before the jump", before_jump))

  -- stop -> play
  for _ = 1, 12 do tick() end
  local before_stop = #T.reader.energies
  state.playing = false
  state.cursor_pos = state.play_pos
  T.read_live_envelope(ITEM, TAKE)

  check("(c) stop resets as well",
    #T.reader.energies == 0,
    string.format("%d frames while playing", before_stop))

  -- shrinking the window trims, it does not reset
  state.playing = true
  for _ = 1, 30 do tick() end
  local wide = #T.reader.energies

  T.set_window_seconds(12)
  tick()
  local narrow = #T.reader.energies

  check("(c) window 24 -> 12 s trims the buffer",
    narrow == T.frames_for_seconds(12) and wide > narrow,
    string.format("%d frames -> %d, want %d", wide, narrow, T.frames_for_seconds(12)))

  -- growing it keeps what is there and fills up again
  T.set_window_seconds(24)
  tick()

  check("(c) window 12 -> 24 s keeps the buffer and grows",
    #T.reader.energies > narrow,
    string.format("%d frames -> %d", narrow, #T.reader.energies))

  -- another take drops the accessor
  local created_before = state.accessors_created
  local destroyed_before = state.accessors_destroyed
  T.read_live_envelope(ITEM, "other take")

  check("(c) another take: old accessor destroyed, new one made",
    state.accessors_created == created_before + 1
      and state.accessors_destroyed == destroyed_before + 1,
    string.format("created %d, destroyed %d", state.accessors_created, state.accessors_destroyed))
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
