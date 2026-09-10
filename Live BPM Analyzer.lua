-- Live BPM Analyzer
-- Estimates BPM from the selected audio item while REAPER is playing.
-- Precision mode analyzes a long span of the song for sub-0.1 BPM accuracy.

local SCRIPT_TITLE = "Live BPM Analyzer"

local folder = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""

-- The only loader code left inline: something has to load the loader. The rest
-- was copied word for word into all four plugins and now lives in
-- steelblue_boot.lua.
local boot_chunk = loadfile(folder .. "steelblue_boot.lua")
if not boot_chunk then
  reaper.ShowMessageBox(
    "steelblue_boot.lua is missing next to this script.\n\n" ..
    "Please copy the whole steelblue package into the same folder.",
    SCRIPT_TITLE,
    0
  )
  return
end

local BOOT = boot_chunk()

local function load_module(name)
  return BOOT.load_module(folder, name, SCRIPT_TITLE)
end

local SAMPLE_RATE = 11025
local FRAME_SIZE = 512
local HOP_SIZE = 128
local UPDATE_INTERVAL = 0.75
-- How much of a defer frame the live tempo search may take. A frame at 60 Hz is
-- ~16 ms; anything much above this and the playback cursor starts to stutter.
local LIVE_STEP_BUDGET = 0.004
local MIN_ANALYSIS_SECONDS = 4
local PRECISION_MAX_SECONDS = 120
local PRECISION_MIN_SECONDS = 12

local HARMONIC_WEIGHTS = { 1.0, 0.6, 0.4 }

-- Confidence calibration. A rival tempo only counts against the result if it
-- sits outside the winning peak's flank and is not an octave relative --
-- see pick_rival() for why. Floors/spans map raw correlation values onto 0..1;
-- they are measured, not guessed (white noise still scores ~0.53 on the comb,
-- so a floor of 0.45 is what keeps noise from reading as a confident result).
local RIVAL_EXCLUSION_RATIO = 0.08
local OCTAVE_RATIOS = { 0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1.5, 2, 3, 4 }
local OCTAVE_HINT_SHARE = 0.75
local COMB_SCORE_FLOOR = 0.45
local COMB_SCORE_SPAN = 0.35
local REFINE_QUALITY_FLOOR = 0.25
local REFINE_QUALITY_SPAN = 0.35

local bpm_min = 60
local bpm_max = 200
local window_seconds = 24
local live_update = true

local last_update = 0
local current_bpm = nil
local raw_bpm = nil
local confidence = 0
local raw_confidence = 0
local status = "Select the finished song item and press play."
local octave_note = nil
local history = {}
local max_history = 9
-- Cost of the last live pass, in milliseconds, per stage. The live loop runs
-- analyze_now() in the UI thread, so this is the number that decides whether
-- the playback cursor moves smoothly. Shown in the footer.
local last_analysis_ms = nil
-- The live tempo search in progress, stepped a few milliseconds per frame.
local pending_estimate = nil
local pending_envelope_ms = 0
local pending_estimate_ms = 0

local function get_selected_audio_take()
  local item = reaper.GetSelectedMediaItem(0, 0)

  if not item then
    local play_pos = reaper.GetPlayPosition()
    if reaper.GetPlayState() & 1 ~= 1 then
      play_pos = reaper.GetCursorPosition()
    end

    local audio_items = {}
    local track_count = reaper.CountTracks(0)

    for track_index = 0, track_count - 1 do
      local track = reaper.GetTrack(0, track_index)
      local item_count = reaper.CountTrackMediaItems(track)

      for item_index = 0, item_count - 1 do
        local candidate_item = reaper.GetTrackMediaItem(track, item_index)
        local candidate_take = candidate_item and reaper.GetActiveTake(candidate_item)

        if candidate_take and not reaper.TakeIsMIDI(candidate_take) then
          local item_start = reaper.GetMediaItemInfo_Value(candidate_item, "D_POSITION")
          local item_end = item_start + reaper.GetMediaItemInfo_Value(candidate_item, "D_LENGTH")

          if play_pos >= item_start and play_pos <= item_end then
            item = candidate_item
            break
          end

          audio_items[#audio_items + 1] = candidate_item
        end
      end

      if item then
        break
      end
    end

    if not item and #audio_items == 1 then
      item = audio_items[1]
    end
  end

  if not item then
    return nil, nil, "Select the song item or place the play cursor inside it."
  end

  local take = reaper.GetActiveTake(item)
  if not take then
    return nil, nil, "Selected item has no active take."
  end

  if reaper.TakeIsMIDI(take) then
    return nil, nil, "Selected item is MIDI. Please select the finished audio song item."
  end

  return item, take, nil
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function median(values)
  if #values == 0 then
    return nil
  end

  local copy = {}
  for index, value in ipairs(values) do
    copy[index] = value
  end

  table.sort(copy)
  local middle = math.floor((#copy + 1) / 2)

  if #copy % 2 == 1 then
    return copy[middle]
  end

  return (copy[middle] + copy[middle + 1]) / 2
end

local function mean(values)
  if #values == 0 then
    return 0
  end

  local sum = 0
  for _, value in ipairs(values) do
    sum = sum + value
  end

  return sum / #values
end

local function standard_deviation(values, values_mean)
  if #values < 2 then
    return 0
  end

  local sum = 0
  for _, value in ipairs(values) do
    local diff = value - values_mean
    sum = sum + diff * diff
  end

  return math.sqrt(sum / (#values - 1))
end

local function push_history(value)
  history[#history + 1] = value
  while #history > max_history do
    table.remove(history, 1)
  end

  return median(history)
end

local function get_sample(buffer, sample_index, channel_count)
  local sum = 0
  local base = (sample_index - 1) * channel_count

  for channel = 1, channel_count do
    sum = sum + math.abs(buffer[base + channel] or 0)
  end

  return sum / channel_count
end

-- How many frames a span of that many seconds produces. The live buffer is
-- trimmed with this so a rolling 24 s window holds exactly as many frames as
-- one batch read of 24 s did.
local function frames_for_seconds(seconds)
  return math.floor(((seconds * SAMPLE_RATE) - FRAME_SIZE) / HOP_SIZE) + 1
end

-- Frame energies (RMS over FRAME_SIZE samples, one value every HOP_SIZE),
-- appended to `out`. Returns how many frames were appended.
--
-- This is the expensive half of the envelope -- one Lua operation per sample --
-- and it is split out so the live loop can run it on the newest audio only.
-- The frame grid therefore has to continue across chunk boundaries: a chunk
-- must start at the first sample of the next frame, not at the end of the last
-- chunk, which leaves up to FRAME_SIZE samples of overlap between the two.
local function energies_for_samples(buffer, sample_count, channel_count, out)
  local frame_count = math.floor((sample_count - FRAME_SIZE) / HOP_SIZE) + 1
  if frame_count < 1 then
    return 0
  end

  local first = #out

  for frame = 1, frame_count do
    local first_sample = ((frame - 1) * HOP_SIZE) + 1
    local energy = 0

    for offset = 0, FRAME_SIZE - 1 do
      local sample_value = get_sample(buffer, first_sample + offset, channel_count)
      energy = energy + sample_value * sample_value
    end

    out[first + frame] = math.sqrt(energy / FRAME_SIZE)
  end

  return frame_count
end

-- Keep only the newest `max_frames` energies. Shared by the live reader and its
-- test so both trim the same way.
local function trim_energies(energies, max_frames)
  local excess = #energies - max_frames

  if excess <= 0 then
    return energies
  end

  local kept = {}
  for index = excess + 1, #energies do
    kept[index - excess] = energies[index]
  end

  return kept
end

-- The cheap half: onset deltas, adaptive threshold, sqrt. It walks frames
-- (~2000 for a 24 s window), not samples, so the live loop can afford to run it
-- over the whole rolling buffer on every update.
local function envelope_from_energies(energies)
  local frame_count = #energies
  if frame_count < 8 then
    return nil
  end

  local energy_sum = 0
  for frame = 1, frame_count do
    energy_sum = energy_sum + energies[frame]
  end

  local mean_energy = energy_sum / frame_count
  local onset_deltas = {}
  local previous_energy = energies[1] or 0

  for frame = 1, frame_count do
    local energy = energies[frame]
    local onset = math.max(0, energy - previous_energy)

    if energy < mean_energy * 0.35 then
      onset = 0
    end

    onset_deltas[frame] = onset
    previous_energy = (previous_energy * 0.65) + (energy * 0.35)
  end

  local onset_mean = mean(onset_deltas)
  local onset_std = standard_deviation(onset_deltas, onset_mean)

  if onset_mean <= 0 and onset_std <= 0 then
    return nil
  end

  local threshold = onset_mean + onset_std * 0.35
  local onsets = {}
  local active_sum = 0

  for frame = 1, frame_count do
    local onset = math.max(0, onset_deltas[frame] - threshold)
    onsets[frame] = math.sqrt(onset)
    active_sum = active_sum + onsets[frame]
  end

  if active_sum <= 0 then
    threshold = onset_mean

    for frame = 1, frame_count do
      local onset = math.max(0, onset_deltas[frame] - threshold)
      onsets[frame] = math.sqrt(onset)
      active_sum = active_sum + onsets[frame]
    end
  end

  if active_sum <= 0 then
    return nil
  end

  return onsets
end

-- Batch envelope over one contiguous buffer: what "Analyze now" and the
-- precision pass use, and what the accuracy suites measure.
local function build_onset_envelope(buffer, sample_count, channel_count)
  local energies = {}
  energies_for_samples(buffer, sample_count, channel_count, energies)
  return envelope_from_energies(energies)
end

local function interpolated_value(values, position)
  local lower = math.floor(position)
  local upper = lower + 1
  local fraction = position - lower

  if lower < 1 or upper > #values then
    return 0
  end

  return (values[lower] * (1 - fraction)) + (values[upper] * fraction)
end

local function lag_correlation(onsets, lag)
  local score = 0
  local current_energy = 0
  local previous_energy = 0
  local start_frame = math.floor(lag) + 2

  if start_frame >= #onsets then
    return 0
  end

  for frame = start_frame, #onsets do
    local current = onsets[frame]
    if current > 0 then
      local previous = interpolated_value(onsets, frame - lag)
      score = score + (current * previous)
      current_energy = current_energy + (current * current)
      previous_energy = previous_energy + (previous * previous)
    end
  end

  if current_energy <= 0 or previous_energy <= 0 then
    return 0
  end

  return score / math.sqrt(current_energy * previous_energy)
end

-- Comb score: correlation at 1x, 2x, 3x the beat lag. Rewards candidates whose
-- multiples also line up, which suppresses the sub-beat bias of a single lag.
local function comb_score(onsets, frame_rate, bpm)
  local base_lag = (60 / bpm) * frame_rate
  local total = 0
  local weight_total = 0

  for harmonic, weight in ipairs(HARMONIC_WEIGHTS) do
    local lag = base_lag * harmonic
    if lag <= #onsets * 0.7 then
      total = total + (lag_correlation(onsets, lag) * weight)
      weight_total = weight_total + weight
    end
  end

  if weight_total <= 0 then
    return 0
  end

  return total / weight_total
end

local function shifted_correlation(onsets, lag)
  local overlap = #onsets - lag
  if overlap < 8 then
    return 0
  end

  local score = 0
  local head_energy = 0
  local tail_energy = 0

  for frame = 1, overlap do
    local head = onsets[frame]
    local tail = onsets[frame + lag]
    score = score + (head * tail)
    head_energy = head_energy + (head * head)
    tail_energy = tail_energy + (tail * tail)
  end

  if head_energy <= 0 or tail_energy <= 0 then
    return 0
  end

  return score / math.sqrt(head_energy * tail_energy)
end

-- Long-lag refinement: locate the correlation peak near `beats` whole beats,
-- then divide the interpolated peak lag by the beat count. Any residual bias or
-- quantization error in the peak position is divided by `beats`, which is what
-- pushes the estimate below 0.1 BPM error on steady-tempo songs.
local function refine_period(onsets, period, beats)
  local center = beats * period
  -- Radius must stay below 0.5 beat: songs with offbeat hats have correlation
  -- peaks at half-beat multiples too, and locking onto one of those skews the
  -- result by percent amounts. 0.25 keeps only the whole-beat peak in view.
  local search_radius = period * 0.25
  local min_lag = math.max(1, math.floor(center - search_radius))
  local max_lag = math.min(#onsets - 8, math.ceil(center + search_radius))

  if min_lag + 2 > max_lag then
    return nil, 0
  end

  local scores = {}
  local best_lag = nil
  local best_score = -1

  for lag = min_lag, max_lag do
    local score = shifted_correlation(onsets, lag)
    scores[lag] = score

    if score > best_score then
      best_score = score
      best_lag = lag
    end
  end

  if not best_lag or best_score <= 0 then
    return nil, 0
  end

  -- A best score at the window edge means the real peak lies outside the
  -- search window; using it would bias the period. Reject instead.
  if best_lag == min_lag or best_lag == max_lag then
    return nil, 0
  end

  local refined_lag = best_lag
  local left = scores[best_lag - 1]
  local right = scores[best_lag + 1]

  if left and right then
    local denominator = left - (2 * best_score) + right
    if math.abs(denominator) > 1e-12 then
      local delta = 0.5 * (left - right) / denominator
      if delta > -1 and delta < 1 then
        refined_lag = best_lag + delta
      end
    end
  end

  local beat_count = math.floor((refined_lag / period) + 0.5)
  if beat_count < 1 then
    return nil, 0
  end

  return refined_lag / beat_count, best_score
end

-- Mild tempo prior centered near 120 BPM. Octave candidates (65 vs 130) often
-- score nearly identically in the comb search; the prior breaks the tie toward
-- the musically more likely tempo. Half/Double buttons remain the override.
local function tempo_prior(bpm)
  local octaves = math.log(bpm / 120) / math.log(2)
  return math.exp(-0.5 * ((octaves / 0.9) ^ 2))
end

local function is_octave_related(bpm, best_bpm)
  for _, ratio in ipairs(OCTAVE_RATIOS) do
    local target = best_bpm * ratio
    if math.abs(bpm - target) < math.max(1.5, target * 0.03) then
      return true
    end
  end

  return false
end

-- Find the best genuinely competing tempo, for the confidence dominance term.
-- Two exclusions, both measured against real material:
--  * Anything within +-8% of the winner is the same correlation hill, not a
--    rival. The comb landscape of a real song is one broad peak ~25 BPM wide;
--    the old "best candidate >=3 BPM away" rule just sampled its own flank at
--    ~90% and capped confidence near 55% no matter how clear the beat was.
--  * Octave relatives (half/double/three-quarter time) describe the same beat
--    grid, so they must not count against confidence in the *number* -- the
--    Half/Double buttons exist for that choice. A strong one is surfaced
--    separately as an octave hint.
local function pick_rival(candidates, best_bpm)
  local exclusion = best_bpm * RIVAL_EXCLUSION_RATIO
  local rival_bpm = nil
  local rival_score = 0

  for index = 2, #candidates - 1 do
    local candidate = candidates[index]
    local is_local_max = candidate.score >= candidates[index - 1].score
      and candidate.score > candidates[index + 1].score

    if is_local_max
      and math.abs(candidate.bpm - best_bpm) > exclusion
      and not is_octave_related(candidate.bpm, best_bpm)
      and candidate.score > rival_score then
      rival_score = candidate.score
      rival_bpm = candidate.bpm
    end
  end

  return rival_bpm, rival_score
end

local function pick_octave_hint(candidates, best_bpm, best_score)
  local hint_bpm = nil
  local hint_score = 0

  for _, candidate in ipairs(candidates) do
    if is_octave_related(candidate.bpm, best_bpm)
      and math.abs(candidate.bpm - best_bpm) > best_bpm * RIVAL_EXCLUSION_RATIO
      and candidate.score > hint_score then
      hint_score = candidate.score
      hint_bpm = candidate.bpm
    end
  end

  if hint_bpm and best_score > 0 and (hint_score / best_score) >= OCTAVE_HINT_SHARE then
    return hint_bpm, hint_score / best_score
  end

  return nil, 0
end

local function decimate_envelope(onsets)
  local decimated = {}

  for index = 1, math.floor(#onsets / 2) do
    local left = onsets[(index * 2) - 1]
    local right = onsets[index * 2] or 0
    decimated[index] = (left + right) * 0.5
  end

  return decimated
end

-- The tempo search, sliced so it fits in a defer frame.
--
-- The coarse comb sweep is 281 candidates x 3 harmonics over the decimated
-- envelope: ~18 ms for a 24 s window, ~47 ms for a 60 s one. Run in one go from
-- the UI thread that is a visible hitch in the playback cursor, so the live
-- loop asks for a few milliseconds of it per frame instead.
--
-- `step(budget_seconds)` returns true once the result is on the estimator. It
-- is the same arithmetic in the same order as the straight loop was -- only the
-- wall clock between start and finish changes, never the number that comes out.
-- The final stage (rival, octave hint, long-lag refinement, confidence) is one
-- indivisible step of 2-5 ms; splitting it would mean rewriting refine_period,
-- and that is the accuracy guardrail.
local function start_estimate(onsets)
  local frame_rate = SAMPLE_RATE / HOP_SIZE
  local coarse_envelope = decimate_envelope(onsets)
  local coarse_rate = frame_rate / 2

  if #coarse_envelope < 16 then
    return nil
  end

  local estimator = {
    done = false,
    bpm = nil,
    confidence = 0,
    octave_bpm = nil,
    octave_share = 0,
    steps = 0,
  }

  -- The scored grid, exposed so a test can check that the sweep really covered
  -- it. Comparing the stepper against estimate_bpm cannot: estimate_bpm runs
  -- the same stepper, so a sweep that skipped half the grid would agree with
  -- itself and read green.
  estimator.candidates = {}

  local coarse_min = math.min(bpm_min, bpm_max)
  local coarse_max = math.max(bpm_min, bpm_max)

  local candidates = estimator.candidates
  local best_bpm = nil
  local best_score = 0
  local bpm = coarse_min
  local sweeping = true

  local function finish()
    if not best_bpm then
      return
    end

    -- candidates stay in BPM order: pick_rival needs neighbours to spot local maxima
    local _, rival_score = pick_rival(candidates, best_bpm)
    local octave_bpm, octave_share = pick_octave_hint(candidates, best_bpm, best_score)

    local dominance = 1
    if best_score > 0 and rival_score > 0 then
      dominance = clamp((best_score - rival_score) / best_score, 0, 1)
    end

    -- Two-stage lag refinement on the full-resolution envelope: a short span
    -- first (kills the coarse-grid error safely), then the longest span that
    -- still leaves enough overlap for a stable correlation.
    local period = (60 / best_bpm) * frame_rate
    local refine_quality = 0
    local max_beats = math.floor((#onsets * 0.7) / period)
    local stage_one_beats = math.min(8, max_beats)

    if stage_one_beats >= 2 then
      local refined, peak = refine_period(onsets, period, stage_one_beats)

      if refined and peak > 0.1 then
        period = refined
        refine_quality = peak

        local stage_two_beats = math.floor((#onsets * 0.7) / period)
        if stage_two_beats > stage_one_beats + 2 then
          local refined_two, peak_two = refine_period(onsets, period, stage_two_beats)

          if refined_two and peak_two > 0.1 then
            period = refined_two
            refine_quality = math.max(refine_quality, peak_two)
          end
        end
      end
    end

    estimator.bpm = 60 * frame_rate / period

    local absolute_score = clamp((best_score - COMB_SCORE_FLOOR) / COMB_SCORE_SPAN, 0, 1)
    local refine_score = clamp((refine_quality - REFINE_QUALITY_FLOOR) / REFINE_QUALITY_SPAN, 0, 1)
    estimator.confidence = clamp(
      (dominance * 0.5) + (absolute_score * 0.25) + (refine_score * 0.25),
      0,
      1
    )
    estimator.octave_bpm = octave_bpm
    estimator.octave_share = octave_share
  end

  estimator.step = function(budget_seconds)
    if estimator.done then
      return true
    end

    estimator.steps = estimator.steps + 1
    local deadline = os.clock() + (budget_seconds or 0)

    if sweeping then
      while bpm <= coarse_max do
        local score = comb_score(coarse_envelope, coarse_rate, bpm) * tempo_prior(bpm)
        candidates[#candidates + 1] = { bpm = bpm, score = score }

        if score > best_score then
          best_score = score
          best_bpm = bpm
        end

        bpm = bpm + 0.5

        if os.clock() >= deadline then
          return false
        end
      end

      sweeping = false

      -- the last stage is 2-5 ms in one piece; start it on a fresh budget
      if os.clock() >= deadline then
        return false
      end
    end

    finish()
    estimator.done = true
    return true
  end

  return estimator
end

-- The synchronous estimator: runs the stepper to the end in one call. This is
-- what "Analyze now", the precision pass and the three accuracy suites use, and
-- its numbers must not move.
local function estimate_bpm(onsets)
  local estimator = start_estimate(onsets)
  if not estimator then
    return nil, 0
  end

  while not estimator.step(math.huge) do end

  if not estimator.bpm then
    return nil, 0
  end

  return estimator.bpm, estimator.confidence, estimator.octave_bpm, estimator.octave_share
end

-- One audio accessor per take, kept alive and reused.
--
-- Creating and destroying one per update -- and pulling the whole window
-- through it every time -- is what made a live pass cost ~100 ms of UI-thread
-- time four times a second. The rolling state next to it is the live window:
-- frame energies for the last `window_seconds`, extended by the newest audio on
-- every update instead of rebuilt.
local reader = {
  take = nil,
  accessor = nil,
  channel_count = 2,
  energies = {},
  next_frame_start = 0,   -- sample index into the take of the next frame to emit
  last_end_sample = nil,  -- where the previous update stopped reading
  playing = nil,
}

local function release_accessor()
  if reader.accessor then
    reaper.DestroyAudioAccessor(reader.accessor)
  end

  reader.accessor = nil
  reader.take = nil
  reader.energies = {}
  reader.last_end_sample = nil
end

-- Drop the rolling window and start collecting again at `start_sample`.
--
-- Deliberately at the cursor and not one window before it: back-filling the
-- whole window is the expensive read this rewrite exists to avoid. The price is
-- that after a jump the display needs MIN_ANALYSIS_SECONDS to say anything and
-- `window_seconds` to be as accurate as a batch pass again.
local function reset_window(start_sample)
  reader.energies = {}
  reader.next_frame_start = math.max(0, start_sample)
end

local function accessor_for(take)
  if take ~= reader.take then
    release_accessor()

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then
      return nil, nil, "Could not create audio accessor."
    end

    local source = reaper.GetMediaItemTake_Source(take)
    local channel_count = source and reaper.GetMediaSourceNumChannels(source) or 2

    reader.take = take
    reader.accessor = accessor
    reader.channel_count = clamp(channel_count, 1, 2)
    reader.energies = {}
    reader.last_end_sample = nil
  end

  return reader.accessor, reader.channel_count, nil
end

local function read_samples(take, start_position, duration)
  local accessor, channel_count, accessor_err = accessor_for(take)
  if not accessor then
    return nil, nil, nil, accessor_err
  end

  local sample_count = math.floor(duration * SAMPLE_RATE)
  if sample_count <= FRAME_SIZE then
    return nil, nil, nil, "Analysis window is too short."
  end

  local buffer = reaper.new_array(sample_count * channel_count)
  buffer.clear()

  local ok = reaper.GetAudioAccessorSamples(
    accessor,
    SAMPLE_RATE,
    channel_count,
    start_position,
    sample_count,
    buffer
  )

  if ok ~= 1 then
    return nil, nil, nil, "Could not read audio samples."
  end

  return buffer, sample_count, channel_count, nil
end

local function read_analysis_window(item, take)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local play_pos = reaper.GetPlayPosition()

  if reaper.GetPlayState() & 1 ~= 1 then
    play_pos = reaper.GetCursorPosition()
  end

  local analysis_end = clamp(play_pos, item_start, item_end)
  local analysis_start = math.max(item_start, analysis_end - window_seconds)
  local duration = analysis_end - analysis_start

  if duration < MIN_ANALYSIS_SECONDS then
    return nil, nil, nil, "Need at least " .. tostring(MIN_ANALYSIS_SECONDS) .. " seconds of audio before the cursor."
  end

  return read_samples(take, analysis_start - item_start, duration)
end

-- The live window, read incrementally.
--
-- Each update reads only the audio that is new since the last one, turns it
-- into frame energies and appends them to the rolling buffer; the buffer is
-- trimmed to `window_seconds` and the cheap envelope passes run over it. The
-- chunk starts at the first sample of the next frame, which leaves up to
-- FRAME_SIZE samples of overlap with the previous chunk -- without that overlap
-- the frames straddling a chunk boundary would simply be missing.
--
-- The buffer is thrown away and refilled when the audio under the cursor stops
-- being a continuation of what is already in it: another take, the cursor
-- jumping (backwards, or further ahead than a normal update step), playback
-- starting or stopping, or REAPER reporting that the take's samples changed
-- under the accessor. Changing `window_seconds` needs no reset: a shorter
-- window is trimmed out of the buffer, a longer one simply fills up.
local function read_live_envelope(item, take)
  local accessor, channel_count, accessor_err = accessor_for(take)
  if not accessor then
    return nil, accessor_err
  end

  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local playing = (reaper.GetPlayState() & 1) == 1
  local play_pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()

  local analysis_end = clamp(play_pos, item_start, item_end)
  local end_sample = math.floor((analysis_end - item_start) * SAMPLE_RATE)
  local max_frames = math.max(1, frames_for_seconds(window_seconds))

  -- A live analysis step is UPDATE_INTERVAL of audio; twice that is the slack
  -- for a late defer frame. Anything beyond it is a jump, not scheduling jitter.
  local step_limit = math.floor(UPDATE_INTERVAL * 2 * SAMPLE_RATE)
  local stale = reaper.AudioAccessorValidateState
    and reaper.AudioAccessorValidateState(accessor)

  if stale and reaper.AudioAccessorUpdate then
    reaper.AudioAccessorUpdate(accessor)
  end

  local continues = reader.last_end_sample
    and not stale
    and playing == reader.playing
    and end_sample >= reader.last_end_sample
    and (end_sample - reader.last_end_sample) <= step_limit

  if not continues then
    reset_window(end_sample)
  end

  reader.last_end_sample = end_sample
  reader.playing = playing

  local available = end_sample - reader.next_frame_start

  if available >= FRAME_SIZE then
    local buffer = reaper.new_array(available * channel_count)
    buffer.clear()

    local ok = reaper.GetAudioAccessorSamples(
      accessor,
      SAMPLE_RATE,
      channel_count,
      reader.next_frame_start / SAMPLE_RATE,
      available,
      buffer
    )

    if ok ~= 1 then
      return nil, "Could not read audio samples."
    end

    local frames = energies_for_samples(buffer, available, channel_count, reader.energies)
    reader.next_frame_start = reader.next_frame_start + (frames * HOP_SIZE)
  end

  reader.energies = trim_energies(reader.energies, max_frames)

  if #reader.energies < frames_for_seconds(MIN_ANALYSIS_SECONDS) then
    return nil, "Need at least " .. tostring(MIN_ANALYSIS_SECONDS) .. " seconds of audio before the cursor."
  end

  local onsets = envelope_from_energies(reader.energies)
  if not onsets then
    return nil, "Could not find enough rhythmic transients."
  end

  return onsets, nil
end

local function read_precision_window(item, take)
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  if item_length < PRECISION_MIN_SECONDS then
    return nil, nil, nil,
      "Precision pass needs at least " .. tostring(PRECISION_MIN_SECONDS) .. " seconds of audio.",
      0
  end

  -- Analyze up to PRECISION_MAX_SECONDS. For longer songs take the middle of
  -- the item, which usually has the steadiest beat (skips intro/outro).
  local duration = math.min(item_length, PRECISION_MAX_SECONDS)
  local offset = 0

  if item_length > duration then
    offset = (item_length - duration) / 2
  end

  local buffer, sample_count, channel_count, err = read_samples(take, offset, duration)
  return buffer, sample_count, channel_count, err, duration
end

local function format_octave_note(octave_bpm, octave_share)
  if not octave_bpm then
    return nil
  end

  return string.format(
    "Octave: %.2f also fits (%.0f%% as strong) -- use Half/Double if that is the beat you count.",
    octave_bpm,
    octave_share * 100
  )
end

-- The footer says what the plugin is doing; in live mode it also says what one
-- pass cost, because that is the number a stuttering cursor is complaining about.
local function status_line()
  if not last_analysis_ms then
    return status
  end

  return status .. string.format(" - analysis %.1f ms", last_analysis_ms.total)
end

-- Everything a finished estimate does to the displayed state. Shared by the
-- button and the live loop so the two cannot drift apart.
local function apply_estimate(estimated_bpm, detected_confidence, octave_bpm, octave_share)
  raw_bpm = estimated_bpm
  current_bpm = push_history(estimated_bpm)
  raw_confidence = detected_confidence
  octave_note = format_octave_note(octave_bpm, octave_share)

  if #history >= 3 then
    local history_mean = mean(history)
    local history_std = standard_deviation(history, history_mean)
    local stability = clamp(1 - (history_std / 2), 0, 1)
    confidence = clamp((detected_confidence * 0.65) + (stability * 0.35), 0, 1)
  else
    confidence = detected_confidence
  end

  status = "Analyzing selected item while playback runs."
end

-- The "Analyze now" button: one batch pass over the whole window, answer on the
-- same frame. It is allowed to be expensive -- the user asked for it once, and
-- a single stutter on a click is not a stuttering cursor.
local function analyze_now()
  local item, take, err = get_selected_audio_take()
  if err then
    status = err
    return
  end

  local started = reaper.time_precise()

  local buffer, sample_count, channel_count, read_err = read_analysis_window(item, take)
  if read_err then
    status = read_err
    return
  end

  local after_read = reaper.time_precise()

  local onsets = build_onset_envelope(buffer, sample_count, channel_count)
  if not onsets then
    status = "Could not find enough rhythmic transients."
    return
  end

  local after_envelope = reaper.time_precise()

  local estimated_bpm, detected_confidence, octave_bpm, octave_share = estimate_bpm(onsets)
  if not estimated_bpm then
    status = "No stable BPM candidate found."
    return
  end

  local after_estimate = reaper.time_precise()
  last_analysis_ms = {
    read = (after_read - started) * 1000,
    envelope = (after_envelope - after_read) * 1000,
    estimate = (after_estimate - after_envelope) * 1000,
    total = (after_estimate - started) * 1000,
  }

  pending_estimate = nil
  apply_estimate(estimated_bpm, detected_confidence, octave_bpm, octave_share)
end

-- The live path, called from the defer loop once per UPDATE_INTERVAL. Reads
-- only the newest audio, runs the cheap envelope passes over the rolling
-- window, and hands the tempo search to the stepper -- which the frames after
-- this one work off a few milliseconds at a time.
local function analyze_live()
  local item, take, err = get_selected_audio_take()
  if err then
    status = err
    return
  end

  local started = reaper.time_precise()

  local onsets, read_err = read_live_envelope(item, take)
  if read_err then
    status = read_err
    return
  end

  pending_envelope_ms = (reaper.time_precise() - started) * 1000
  pending_estimate_ms = 0
  pending_estimate = start_estimate(onsets)

  if not pending_estimate then
    status = "No stable BPM candidate found."
  end
end

-- One slice of the live tempo search. Runs on every defer frame; the result is
-- only shown once the search is finished, never as an intermediate value.
local function step_live_estimate()
  if not pending_estimate then
    return
  end

  local started = reaper.time_precise()
  local finished = pending_estimate.step(LIVE_STEP_BUDGET)
  pending_estimate_ms = pending_estimate_ms + ((reaper.time_precise() - started) * 1000)

  if not finished then
    return
  end

  local estimator = pending_estimate
  pending_estimate = nil

  if not estimator.bpm then
    status = "No stable BPM candidate found."
    return
  end

  last_analysis_ms = {
    read = 0,
    envelope = pending_envelope_ms,
    estimate = pending_estimate_ms,
    total = pending_envelope_ms + pending_estimate_ms,
  }

  apply_estimate(estimator.bpm, estimator.confidence, estimator.octave_bpm, estimator.octave_share)
end

local function precision_analyze()
  local item, take, err = get_selected_audio_take()
  if err then
    status = err
    return
  end

  local buffer, sample_count, channel_count, read_err, analyzed_seconds = read_precision_window(item, take)
  if read_err then
    status = read_err
    return
  end

  local onsets = build_onset_envelope(buffer, sample_count, channel_count)
  if not onsets then
    status = "Precision pass: could not find enough rhythmic transients."
    return
  end

  local estimated_bpm, detected_confidence, octave_bpm, octave_share = estimate_bpm(onsets)
  if not estimated_bpm then
    status = "Precision pass: no stable BPM candidate found."
    return
  end

  raw_bpm = estimated_bpm
  current_bpm = estimated_bpm
  history = { estimated_bpm }
  raw_confidence = detected_confidence
  confidence = detected_confidence
  octave_note = format_octave_note(octave_bpm, octave_share)
  live_update = false
  pending_estimate = nil

  status = string.format(
    "Precision result from %.0f s of audio. Live updates paused so the value stays.",
    analyzed_seconds
  )
end

local function get_project_timebase()
  if not reaper.GetSetProjectInfo then
    return nil
  end

  local ok, value = pcall(reaper.GetSetProjectInfo, 0, "PROJECT_TIMEBASE", 0, false)
  if ok then
    return value
  end

  return nil
end

local function set_project_timebase(value)
  if value and reaper.GetSetProjectInfo then
    pcall(reaper.GetSetProjectInfo, 0, "PROJECT_TIMEBASE", value, true)
  end
end

local function collect_all_item_states()
  local item_states = {}
  local track_count = reaper.CountTracks(0)

  for track_index = 0, track_count - 1 do
    local track = reaper.GetTrack(0, track_index)
    local item_count = reaper.CountTrackMediaItems(track)

    for item_index = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(track, item_index)
      local take = item and reaper.GetActiveTake(item)

      item_states[#item_states + 1] = {
        item = item,
        position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
        snap_offset = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET"),
        beat_attach_mode = reaper.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE"),
        take = take,
        start_offset = take and reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or nil,
        playrate = take and reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or nil,
      }
    end
  end

  return item_states
end

local function force_items_to_timebase_time(item_states)
  for _, state in ipairs(item_states) do
    if state.item then
      reaper.SetMediaItemInfo_Value(state.item, "C_BEATATTACHMODE", 0)
    end
  end
end

local function restore_item_states(item_states)
  for _, state in ipairs(item_states) do
    if state.item then
      reaper.SetMediaItemInfo_Value(state.item, "D_POSITION", state.position)
      reaper.SetMediaItemInfo_Value(state.item, "D_LENGTH", state.length)
      reaper.SetMediaItemInfo_Value(state.item, "D_SNAPOFFSET", state.snap_offset)

      if state.take then
        if state.start_offset then
          reaper.SetMediaItemTakeInfo_Value(state.take, "D_STARTOFFS", state.start_offset)
        end

        if state.playrate then
          reaper.SetMediaItemTakeInfo_Value(state.take, "D_PLAYRATE", state.playrate)
        end
      end

      reaper.SetMediaItemInfo_Value(state.item, "C_BEATATTACHMODE", state.beat_attach_mode)
    end
  end
end

local function set_project_tempo()
  if current_bpm then
    local project_timebase = get_project_timebase()
    local item_states = collect_all_item_states()

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    set_project_timebase(0)
    force_items_to_timebase_time(item_states)
    reaper.SetCurrentBPM(0, current_bpm, true)
    restore_item_states(item_states)
    set_project_timebase(project_timebase)

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Set project tempo from live BPM analyzer", -1)

    status = "Project tempo set. Existing item positions and lengths were preserved."
  end
end

local function multiply_current_bpm(factor)
  if current_bpm then
    current_bpm = current_bpm * factor
    raw_bpm = raw_bpm and raw_bpm * factor or current_bpm
    history = { current_bpm }
    raw_confidence = confidence
  end
end

-- Test hook: lets the DSP core run outside REAPER for accuracy verification.
local TEST_HOOK = rawget(_G, "BPM_ANALYZER_TEST")
if TEST_HOOK then
  TEST_HOOK.sample_rate = SAMPLE_RATE
  TEST_HOOK.hop_size = HOP_SIZE
  TEST_HOOK.build_onset_envelope = build_onset_envelope
  TEST_HOOK.energies_for_samples = energies_for_samples
  TEST_HOOK.envelope_from_energies = envelope_from_energies
  TEST_HOOK.trim_energies = trim_energies
  TEST_HOOK.frames_for_seconds = frames_for_seconds
  TEST_HOOK.read_live_envelope = read_live_envelope
  TEST_HOOK.release_accessor = release_accessor
  TEST_HOOK.reader = reader
  TEST_HOOK.frame_size = FRAME_SIZE
  TEST_HOOK.update_interval = UPDATE_INTERVAL
  TEST_HOOK.set_window_seconds = function(seconds) window_seconds = seconds end
  TEST_HOOK.estimate_bpm = estimate_bpm
  TEST_HOOK.start_estimate = start_estimate
  TEST_HOOK.comb_score = comb_score
  TEST_HOOK.tempo_prior = tempo_prior
  TEST_HOOK.decimate_envelope = decimate_envelope
  TEST_HOOK.refine_period = refine_period
  return
end

if not BOOT.has_imgui() then
  reaper.ShowMessageBox("ReaImGui is required for the live BPM analyzer window.", SCRIPT_TITLE, 0)
  return
end

local SB = load_module("steelblue_ui.lua")
if not SB then
  return
end

local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)

local function loop()
  local now = reaper.time_precise()
  -- Never both in one frame: the envelope update and a search slice each cost
  -- a few milliseconds, and together they are back over the frame budget.
  local refreshed = false

  if live_update and now - last_update >= UPDATE_INTERVAL then
    last_update = now
    analyze_live()
    refreshed = true
  end

  if live_update and not refreshed then
    step_live_estimate()
  end

  local visible, open, font = SB.begin_window(ctx, SCRIPT_TITLE, 420)

  if visible then
    SB.section(ctx, "Tempo")
    SB.display_value(ctx, current_bpm and string.format("%.2f", current_bpm) or "--.--", "BPM")
    SB.meter(ctx, confidence, 180)
    SB.label(ctx, string.format("Confidence %.0f%%", confidence * 100))

    reaper.ImGui_Separator(ctx)

    SB.label(ctx, "Raw          " .. (raw_bpm and string.format("%.2f", raw_bpm) or "--.--"))
    SB.label(ctx, string.format("Raw confidence  %.0f%%", raw_confidence * 100))
    SB.label(ctx, string.format("Project tempo   %.2f", reaper.Master_GetTempo()))

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Range")

    reaper.ImGui_SetNextItemWidth(ctx, 90)
    local _
    _, window_seconds = reaper.ImGui_InputInt(ctx, "Window seconds", window_seconds)
    window_seconds = clamp(math.floor(tonumber(window_seconds) or 24), 4, 60)

    reaper.ImGui_SetNextItemWidth(ctx, 90)
    _, bpm_min = reaper.ImGui_InputInt(ctx, "Min BPM", bpm_min)
    bpm_min = clamp(math.floor(tonumber(bpm_min) or 60), 30, 300)

    reaper.ImGui_SetNextItemWidth(ctx, 90)
    _, bpm_max = reaper.ImGui_InputInt(ctx, "Max BPM", bpm_max)
    bpm_max = clamp(math.floor(tonumber(bpm_max) or 200), 30, 300)

    reaper.ImGui_Separator(ctx)
    SB.section(ctx, "Analyze")

    if SB.primary_button(ctx, "Precision analyze", 145) then
      status = "Running precision pass..."
      precision_analyze()
    end

    reaper.ImGui_SameLine(ctx)
    _, live_update = reaper.ImGui_Checkbox(ctx, "Live update", live_update)

    if SB.button(ctx, "Analyze now", 110) then
      history = {}
      analyze_now()
    end

    reaper.ImGui_SameLine(ctx)

    if SB.button(ctx, "Half", 55) then
      multiply_current_bpm(0.5)
    end

    reaper.ImGui_SameLine(ctx)

    if SB.button(ctx, "Double", 70) then
      multiply_current_bpm(2)
    end

    if SB.button(ctx, "Set project tempo", 145) then
      set_project_tempo()
    end

    reaper.ImGui_SameLine(ctx)

    if SB.button(ctx, "Clear", 70) then
      history = {}
      current_bpm = nil
      raw_bpm = nil
      confidence = 0
      raw_confidence = 0
      octave_note = nil
      pending_estimate = nil
    end

    if octave_note then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextWrapped(ctx, octave_note)
    end

    SB.footer(ctx, status_line())
  end

  SB.end_window(ctx, visible, font)

  if open then
    reaper.defer(loop)
  else
    release_accessor()
    BOOT.destroy_context(ctx)
  end
end

reaper.defer(loop)
