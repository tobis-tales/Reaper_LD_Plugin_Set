-- The precision pass runs in steps now: one defer frame reads up to 8 s of
-- audio, one builds the onset envelope, one runs the estimator. Before that it
-- was a single synchronous call that froze the window for seconds with nothing
-- moving on screen (Tobi, TT 64: "kann man sehen, dass es noch analysiert?").
--
-- Slicing an analysis is only allowed if the analysis does not change. The whole
-- accuracy story in AGENTS.md ("4. Live BPM Analyzer") is measured on the buffer
-- the pass reads, so this file asks the two questions that matter:
--
--   * is the assembled buffer the SAME buffer a single
--     read_samples(offset, duration) produced -- sample for sample, not
--     "close enough"?
--   * does the same BPM and the same confidence come out the other end?
--
-- and then the things that can only go wrong now that there is a job: that the
-- reads really are chunked, that the live path stands still while the job runs
-- (two heavy stages in one frame is the stutter this exists to avoid), that the
-- progress the UI shows moves and then goes away, and that an item disappearing
-- under the job cancels it instead of finishing with numbers from nowhere.
--
-- The module is driven directly (BPM.create + panel.tick) rather than through a
-- host: what is under test is the job, not a window.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""
local dylib = folder .. "extensions/macOS/reaper_imgui-arm64.dylib"

local real_imgui = {}
local p = io.popen(string.format("strings %q | grep -oE '^-API_ImGui_[A-Za-z_0-9]+$'", dylib))
for line in p:lines() do real_imgui[line:gsub("^-API_", "")] = true end
p:close()

-- ---------------------------------------------------------------- fake REAPER

local SR = 11025          -- checked against the hook's sample_rate below
local CHUNK_SECONDS = 8   -- PRECISION_READ_CHUNK_SECONDS

local song = {}

local state = {
  item_length = 0,
  item_valid = true,
  play_pos = 0,
  clock = 0,
  reads = {},             -- {start_sample=, sample_count=} per accessor read
  accessors_created = 0,
  accessors_destroyed = 0,
}

-- A reaper.array stand-in. `copy` is the real thing's contract: "Copies values
-- from reaper.array or table, starting at 1-based srcoffs, writing to 1-based
-- destoffs" -- an array that ignored the offsets would let a chunked read that
-- overwrites itself pass, which is the bug this file is here to catch.
local function fake_array(size)
  local array = {}
  array.size = size
  array.clear = function()
    for index = 1, size do array[index] = 0 end
  end
  array.copy = function(src, srcoffs, count, destoffs)
    srcoffs = srcoffs or 1
    destoffs = destoffs or 1
    count = count or src.size
    for index = 0, count - 1 do
      array[destoffs + index] = src[srcoffs + index]
    end
  end
  return array
end

local TRACK = { name = "Song", number = 1 }
local TAKE = { name = "song.wav" }
local ITEM = { track = TRACK, take = TAKE }

local specific = {
  APIExists = function(name)
    if name:match("^ImGui_") then return real_imgui[name] == true end
    return true
  end,
  -- A counter, not the wall clock: the live loop fires once UPDATE_INTERVAL of
  -- "time" has passed, so with a real clock a fast machine would simply never
  -- reach it inside a scenario -- and (e) would stay green with the guard in
  -- tick() removed. One step per call makes every frame a due live pass.
  time_precise = function() state.clock = state.clock + 1 return state.clock end,
  ShowMessageBox = function(m) print("  MSGBOX: " .. tostring(m)) return 6 end,
  Master_GetTempo = function() return 120.0 end,

  GetPlayState = function() return 1 end,
  GetPlayPosition = function() return state.play_pos end,
  GetCursorPosition = function() return state.play_pos end,

  CountTracks = function() return 1 end,
  GetTrack = function(_, index) return index == 0 and TRACK or nil end,
  CountTrackMediaItems = function() return 1 end,
  GetTrackMediaItem = function(_, index) return index == 0 and ITEM or nil end,
  GetActiveTake = function(item) return item.take end,
  TakeIsMIDI = function() return false end,
  GetTakeName = function(take) return take.name end,
  GetMediaItemTrack = function(item) return item.track end,
  GetTrackName = function(track) return true, track.name end,
  GetSelectedMediaItem = function() return nil end,
  GetSetMediaItemInfo_String = function() return true, "" end,
  GetMediaTrackInfo_Value = function(_, key)
    if key == "IP_TRACKNUMBER" then return 1 end
    return 0
  end,
  GetMediaItemInfo_Value = function(_, key)
    if key == "D_POSITION" then return 0 end
    if key == "D_LENGTH" then return state.item_length end
    return 0
  end,

  -- The one switch (g) flips: the item the job is holding goes away.
  ValidatePtr2 = function() return state.item_valid end,

  CreateTakeAudioAccessor = function(take)
    state.accessors_created = state.accessors_created + 1
    return { take = take }
  end,
  DestroyAudioAccessor = function()
    state.accessors_destroyed = state.accessors_destroyed + 1
  end,
  AudioAccessorValidateState = function() return false end,
  GetMediaItemTake_Source = function(take) return { take = take } end,
  GetMediaSourceNumChannels = function() return 1 end,

  -- Reads from the song by time, the way the real accessor does. Every call is
  -- logged: "how often and from where" is most of what this file checks.
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

-- What the last rendered frame submitted. Scenario (f) is the only one that
-- draws, and what it needs to know is which button was drawn inside a
-- BeginDisabled block -- so every button records the disabled depth it was
-- submitted at, rather than the test guessing from a call count.
local drawn = { buttons = {}, texts = {}, bars = {}, rects = {} }
local disabled_depth = 0
local click_label = nil

local function reset_frame()
  drawn = { buttons = {}, texts = {}, bars = {}, rects = {} }
  disabled_depth = 0
end

reaper = setmetatable({}, {
  __index = function(_, key)
    if specific[key] then return specific[key] end
    if not key:match("^ImGui_") then return function() return 0 end end
    if not real_imgui[key] then return nil end

    return function(...)
      local _, a2, a3, a4, a5, a6 = ...

      if key == "ImGui_BeginDisabled" then
        if a2 ~= false then disabled_depth = disabled_depth + 1 end
        return nil
      end
      if key == "ImGui_EndDisabled" then
        disabled_depth = disabled_depth - 1
        return nil
      end
      if key == "ImGui_Button" then
        drawn.buttons[a2] = disabled_depth
        return a2 == click_label
      end
      if key == "ImGui_ProgressBar" then
        drawn.bars[#drawn.bars + 1] = { fraction = a2, overlay = a5 }
        return nil
      end
      if key == "ImGui_DrawList_AddRectFilled" then
        -- (dl, x0, y0, x1, y1, color, rounding): the fill width of the compact
        -- meter is x1 - x0, which is how (f) reads the bar without a screenshot.
        drawn.rects[#drawn.rects + 1] = { x0 = a2, x1 = a4, color = a6 }
        return nil
      end
      if key == "ImGui_TextColored" then drawn.texts[#drawn.texts + 1] = a3 return nil end
      if key == "ImGui_Text" or key == "ImGui_TextWrapped" then
        drawn.texts[#drawn.texts + 1] = a2
        return nil
      end
      if key == "ImGui_Checkbox" then return false, a3 end
      if key == "ImGui_InputInt" or key == "ImGui_InputText" then return false, a3 end
      if key == "ImGui_GetCursorScreenPos" then return 100, 100 end
      if key == "ImGui_GetFrameHeight" then return 23 end
      if key == "ImGui_GetWindowDrawList" then return "dl" end
      if key == "ImGui_GetContentRegionAvail" then return 400, 300 end
      if key:match("^ImGui_Col_") or key:match("^ImGui_StyleVar_")
        or key:match("^ImGui_Cond_") or key:match("Flags") then return 1 end
      return nil
    end
  end,
})

-- ------------------------------------------------------------------ the module

local BPM = dofile(folder .. "steelblue_bpm.lua")
local SB = dofile(folder .. "steelblue_ui.lua")

-- Every scenario gets its own panel. A finished precision pass switches "Live
-- update" off on purpose, and a scenario that needs it on would otherwise
-- silently depend on the order the scenarios happen to run in.
local panel, T

local function fresh_panel()
  if T then T.release_accessor() end
  panel = BPM.create({ title = "Live BPM Analyzer" })
  T = panel.test_hook()
end

fresh_panel()
SR = T.sample_rate

-- ------------------------------------------------------------ synthetic audio
-- Same material as bpm_accuracy_test.lua: kick on the beat, snare on 2 and 4,
-- offbeat hat, low-level noise, +-3 ms jitter.

math.randomseed(12345)

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

  return buf
end

-- --------------------------------------------------------------------- runner

local fails = 0
local function check(name, ok, note)
  if not ok then fails = fails + 1 end
  print(string.format("  %-4s %-54s %s", ok and "PASS" or "FAIL", name, note or ""))
end

local ITEM_SECONDS = 20    -- 8 + 8 + 4: two full chunks and a short last one
local song_cache = nil

local function load_song()
  song = song_cache or make_song(128, ITEM_SECONDS)
  song_cache = song
  state.item_length = ITEM_SECONDS
  state.item_valid = true
  state.play_pos = 0
  state.clock = 0
  state.reads = {}
  fresh_panel()
end

-- One defer frame. tick() is what the host calls on every frame, whatever the
-- panel is doing.
local function frame()
  panel.tick()
end

-- A frame the way the workspace draws one: tick, the compact block, then the
-- queued click after the window would have closed.
local function compact_frame()
  reset_frame()
  panel.tick()
  panel.frame("ctx", SB, { layout = "compact" })
  panel.after_frame()
end

local function has_text(prefix)
  for _, text in ipairs(drawn.texts) do
    if type(text) == "string" and text:sub(1, #prefix) == prefix then
      return text
    end
  end
  return nil
end

print("\nLive BPM Analyzer -- the precision pass, one step per frame:\n")

-- (a) ------------------------------------------------------- reads in chunks
local job_reads, job_result
do
  load_song()
  T.start_precision()

  local job = T.get_precision_job()
  check("(a) the click leaves a job behind",
    job ~= nil and job.phase == "read" and job.item == ITEM,
    job and ("phase " .. job.phase) or "no job")
  check("(a) and not one sample has been read yet",
    #state.reads == 0,
    #state.reads .. " reads")

  local want_chunks = math.ceil(ITEM_SECONDS / CHUNK_SECONDS)
  local positions = {}

  for tick_index = 1, want_chunks do
    frame()
    local live = T.get_precision_job()
    positions[tick_index] = live and live.read_pos or ITEM_SECONDS
  end

  local want_positions = {}
  local position_ok = true
  for index = 1, want_chunks do
    want_positions[index] = math.min(index * CHUNK_SECONDS, ITEM_SECONDS)
    if math.abs(positions[index] - want_positions[index]) > 1e-9 then
      position_ok = false
    end
  end

  check("(a) read_pos after n ticks is min(n x 8 s, duration)",
    position_ok,
    string.format("%s, want %s",
      table.concat(positions, "/"), table.concat(want_positions, "/")))

  check("(a) one accessor read per chunk, ceil(duration / 8)",
    #state.reads == want_chunks,
    string.format("%d reads, want %d", #state.reads, want_chunks))

  local contiguous = true
  local expected_start = 0
  for _, read in ipairs(state.reads) do
    if read.start_sample ~= expected_start then contiguous = false end
    expected_start = expected_start + read.sample_count
  end

  check("(a) the chunks are back to back, no gap and no overlap",
    contiguous and expected_start == math.floor(ITEM_SECONDS * SR),
    string.format("%d samples in %d reads", expected_start, #state.reads))

  job_reads = #state.reads

  -- the envelope frame and the estimate frame
  check("(a) the last chunk hands over to the envelope stage",
    T.get_precision_job() and T.get_precision_job().phase == "envelope",
    T.get_precision_job() and T.get_precision_job().phase or "job gone")

  frame()
  check("(a) the envelope is one frame of its own",
    T.get_precision_job() and T.get_precision_job().phase == "estimate",
    T.get_precision_job() and T.get_precision_job().phase or "job gone")

  frame()
  job_result = T.get_display_state()
  check("(a) and one more frame finishes the pass",
    T.get_precision_job() == nil,
    job_result.status)
end

-- (b) --------------------------------------- the buffer equals a single read
-- Rebuilt the old way: ONE GetAudioAccessorSamples over the whole span, which
-- is the single call read_samples(offset, duration) makes.
local reference_buffer, reference_count
do
  reference_count = math.floor(ITEM_SECONDS * SR)
  reference_buffer = fake_array(reference_count)
  reference_buffer.clear()

  local accessor = reaper.CreateTakeAudioAccessor(TAKE)
  reaper.GetAudioAccessorSamples(accessor, SR, 1, 0, reference_count, reference_buffer)
  reaper.DestroyAudioAccessor(accessor)

  -- The job's buffer is gone with the job, so run a second pass and stop it
  -- one frame before the estimate clears it away.
  load_song()
  T.start_precision()
  for _ = 1, math.ceil(ITEM_SECONDS / CHUNK_SECONDS) do frame() end

  local job = T.get_precision_job()
  local assembled = job and job.buffer

  check("(b) the assembled buffer has the length of a single read",
    assembled ~= nil and job.sample_count == reference_count,
    string.format("%d samples, want %d", job and job.sample_count or -1, reference_count))

  local worst, worst_at, differing = 0, 0, 0
  if assembled then
    for index = 1, reference_count do
      local diff = math.abs((assembled[index] or 0) - reference_buffer[index])
      if diff ~= 0 then differing = differing + 1 end
      if diff > worst then worst = diff worst_at = index end
    end
  end

  check("(b) and every single sample is identical",
    assembled ~= nil and differing == 0,
    string.format("%d of %d samples differ, worst %.3e at %d",
      differing, reference_count, worst, worst_at))

  -- finish the pass so the panel is idle again
  frame()
  frame()
end

-- (c) --------------------------------------- same numbers as the old way
do
  local onsets = T.build_onset_envelope(reference_buffer, reference_count, 1)
  local want_bpm, want_confidence = T.estimate_bpm(onsets)

  check("(c) the old synchronous way still produces a result",
    want_bpm ~= nil,
    string.format("%.4f BPM at %.4f", want_bpm or 0, want_confidence or 0))

  check("(c) the stepped pass produced the same BPM, to the last bit",
    want_bpm and job_result.current_bpm
      and (job_result.current_bpm - want_bpm) == 0,
    string.format("sync %.6f, stepped %.6f", want_bpm or 0, job_result.current_bpm or 0))

  check("(c) and the same confidence",
    ((job_result.confidence or -1) - (want_confidence or 0)) == 0,
    string.format("sync %.6f, stepped %.6f", want_confidence or 0, job_result.confidence or 0))

  check("(c) raw values and history follow the old assignments",
    job_result.raw_bpm == want_bpm
      and job_result.raw_confidence == want_confidence
      and #job_result.history == 1 and job_result.history[1] == want_bpm,
    string.format("raw %.4f, history %d", job_result.raw_bpm or 0, #job_result.history))

  check("(c) and live updates are paused so the value stays",
    job_result.live_update == false,
    job_result.status)
end

-- (d) ------------------------------------------------------------- progress
do
  load_song()

  check("(d) no pass, no progress",
    T.precision_progress() == nil,
    tostring(T.precision_progress()))

  T.start_precision()

  -- Every value the UI would have drawn, in order. The last frame ends the job,
  -- so its progress is nil and never lands in the list -- which is the point of
  -- `after` below.
  local seen = { T.precision_progress() }
  local guard = 0
  while T.get_precision_job() and guard < 50 do
    frame()
    guard = guard + 1
    seen[#seen + 1] = T.precision_progress()
  end
  local after = T.precision_progress()

  local last = #seen
  local monotone = true
  for index = 2, last do
    if seen[index] <= seen[index - 1] then monotone = false end
  end

  local rendered = {}
  for index = 1, last do
    rendered[index] = string.format("%.2f", seen[index])
  end

  check("(d) it starts at 0",
    seen[1] == 0,
    tostring(seen[1]))
  check("(d) and rises strictly, frame by frame, towards 1",
    monotone and last > 3 and seen[last] < 1,
    table.concat(rendered, " -> "))
  check("(d) reading stays under 0.8, then envelope 0.85, estimate 0.95",
    last >= 3 and seen[last] == 0.95 and seen[last - 1] == 0.85
      and seen[last - 2] <= 0.8,
    string.format("%.4f / %.4f / %.4f", seen[last - 2], seen[last - 1], seen[last]))
  check("(d) and is nil again once the pass is done",
    after == nil,
    tostring(after))
end

-- (e) ---------------------------------------- the live path stands still
do
  load_song()

  -- The live path is armed: the switch is on, and the play cursor is moving.
  -- Without the guard in tick() this is exactly the state in which analyze_live
  -- would read audio on the very first frame.
  check("(e) live update is on and a live pass is due every frame",
    T.get_display_state().live_update == true,
    "")

  T.start_precision()

  local energies_seen = 0
  local guard = 0
  while T.get_precision_job() and guard < 50 do
    state.play_pos = state.play_pos + 0.9
    frame()
    guard = guard + 1
    if #T.reader.energies > energies_seen then energies_seen = #T.reader.energies end
  end

  check("(e) only the job's own chunks were read",
    #state.reads == job_reads,
    string.format("%d reads, want %d (%d chunks)", #state.reads, job_reads, job_reads))
  check("(e) and the live rolling window was never filled",
    energies_seen == 0,
    energies_seen .. " frame energies")
end

-- (g) ------------------------------------------- the item goes away mid-pass
do
  load_song()

  -- a value on screen, so "unchanged" can be seen
  T.apply_estimate(128, 0.9)
  local before = T.get_display_state()

  T.start_precision()
  frame()

  check("(g) the pass is under way",
    T.get_precision_job() ~= nil and T.get_precision_job().read_pos > 0,
    "")

  state.item_valid = false
  local reads_before = #state.reads
  frame()

  check("(g) an invalid item cancels the pass",
    T.get_precision_job() == nil,
    "")
  check("(g) with the cancelled status",
    T.get_display_state().status == "Precision pass cancelled: the item changed.",
    T.get_display_state().status)
  check("(g) it reads no further audio",
    #state.reads == reads_before,
    string.format("%d -> %d reads", reads_before, #state.reads))
  check("(g) and live_update is left exactly as it was",
    T.get_display_state().live_update == before.live_update,
    tostring(T.get_display_state().live_update))
  check("(g) progress is gone with the job",
    T.precision_progress() == nil,
    "")
end


-- (f) ------------------------------------------- what the layouts show
do
  load_song()

  -- One frame first: the live path picks the item on it, and picking a new item
  -- clears the read-out on purpose. Only after that is a value put on screen
  -- something the next frames have to keep showing.
  compact_frame()
  T.apply_estimate(128, 0.5)

  compact_frame()
  check("(f) idle: the button is enabled",
    drawn.buttons["Precision analyze"] == 0,
    "disabled depth " .. tostring(drawn.buttons["Precision analyze"]))

  -- the confidence bar, so the progress bar below can be told apart from it
  local idle_fill = drawn.rects[2] and (drawn.rects[2].x1 - drawn.rects[2].x0)
  check("(f) and the bar shows confidence",
    idle_fill and math.abs(idle_fill - (0.5 * 46)) < 1e-9,
    string.format("%.2f px of 46", idle_fill or -1))

  click_label = "Precision analyze"
  compact_frame()
  click_label = nil

  local job = T.get_precision_job()
  check("(f) clicking it starts the pass after the frame",
    job ~= nil,
    job and job.phase or "no job")

  compact_frame()
  local progress = T.precision_progress()

  check("(f) and from then on the button is drawn disabled",
    drawn.buttons["Precision analyze"] == 1,
    "disabled depth " .. tostring(drawn.buttons["Precision analyze"]))
  check("(f) and the disabled block is closed again before the frame ends",
    disabled_depth == 0,
    "depth " .. disabled_depth)
  check("(f) while >>> stays clickable",
    drawn.buttons["\u{203A}\u{203A}\u{203A}"] == 0,
    "disabled depth " .. tostring(drawn.buttons["\u{203A}\u{203A}\u{203A}"]))

  local fill = drawn.rects[2] and (drawn.rects[2].x1 - drawn.rects[2].x0)
  check("(f) the bar now shows the progress, in the same blue",
    fill and math.abs(fill - (progress * 46)) < 1e-9
      and drawn.rects[2].color == SB.color.blue,
    string.format("%.2f px, want %.2f", fill or -1, (progress or 0) * 46))
  check("(f) and the read-out still shows the last value",
    has_text("128.00") ~= nil,
    table.concat({ tostring(has_text("128.00")) }, ""))

  -- a second click while the pass runs. The fake button does not honour
  -- BeginDisabled -- which is the point: this is on_precision's own guard.
  local before = T.get_precision_job()
  local read_before = before.read_pos
  click_label = "Precision analyze"
  compact_frame()
  click_label = nil

  check("(f) a second click does not restart the pass",
    T.get_precision_job() == before and T.get_precision_job().read_pos > read_before,
    string.format("read_pos %.1f -> %.1f", read_before, T.get_precision_job().read_pos))

  -- the popup swaps one row for the other
  reset_frame()
  panel.popup("ctx", SB)
  check("(f) the popup says how far along the pass is",
    has_text("Precision pass") ~= nil and has_text("Last analysis") == nil,
    tostring(has_text("Precision pass")))

  -- and the single script's own window grows a progress bar
  reset_frame()
  panel.frame("ctx", SB, { layout = "window" })
  check("(f) the window draws a progress bar with the percentage on it",
    #drawn.bars == 1 and drawn.bars[1].fraction == T.precision_progress()
      and drawn.bars[1].overlay == string.format("Precision pass %d%%",
        math.floor(T.precision_progress() * 100)),
    drawn.bars[1] and tostring(drawn.bars[1].overlay) or "no bar")

  -- run it out; both layouts go back to what they were
  local guard = 0
  while T.get_precision_job() and guard < 50 do compact_frame() guard = guard + 1 end

  check("(f) when it is over the button is enabled again",
    drawn.buttons["Precision analyze"] == 0,
    "disabled depth " .. tostring(drawn.buttons["Precision analyze"]))

  reset_frame()
  panel.frame("ctx", SB, { layout = "window" })
  check("(f) and the window has no bar left",
    #drawn.bars == 0,
    #drawn.bars .. " bars")

  reset_frame()
  panel.popup("ctx", SB)
  check("(f) the popup says what the last analysis cost again",
    has_text("Last analysis") ~= nil and has_text("Precision pass") == nil,
    tostring(has_text("Last analysis")))
end

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
