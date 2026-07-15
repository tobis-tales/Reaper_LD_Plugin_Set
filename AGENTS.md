# AGENTS.md

## Project

Custom REAPER Lua scripts for Tobias P. — the "steelblue studios" LD plugin set.

**The project is this folder, and it is a git repository (since 2026-07-15):**

- `/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket`
- private remote: `https://github.com/tobis-tales/Reaper_LD_Plugin_Set`

`Plugin Factory` one level up is **Tobi's workbench, not the project** — it also holds unrelated things (TimecodeMaker, ReciepeTagToggle, an old Windows installer, and `X - StickyDrag`, which is a C/Swift project with three git repos of its own). Do not widen the repo to that level: it was tried and git immediately produced broken gitlinks for StickyDrag's nested repos.

Everything the project needs now lives inside the repo: the plugins, `AGENTS.md`, `tests/`, `Demo Project/`, `Tutorials/`.

**Why version control, in one line:** on 2026-07-15 an hour was lost because seven stale copies of the plugins were lying around and REAPER had been launching a day-old file unnoticed. Commit, don't copy.

### Worth knowing about the workbench folder

- **`../ReaperRenameMarkersInstaller/`** — a Windows installer Tobi built for an earlier plugin, bundling ReaPack, JS_ReaScriptAPI (`reaper_js_ReaScriptAPI64.dll`) and SWS. Useful prior art for the planned installer, and its `readme.txt` **confirms the central constraint**: after all that installing, the user still had to open the Action List and "Load ReaScript..." by hand. An external installer cannot register the action — that is exactly the gap the new in-REAPER install script closes. It is outside the repo; pull it in if it becomes a reference.

**This package folder is also what REAPER actually runs** (corrected 2026-07-15 — see below). All four scripts are registered to it in `reaper-kb.ini`.

### Where REAPER runs scripts from — check this, do not assume

`~/Library/Application Support/REAPER/Scripts` is the conventional install location and **was wrongly documented here as the active one**. On this machine REAPER does not run any of the four plugins from there. The truth lives in the action list, i.e. in:

- `/Users/tobiaspehla/Library/Application Support/REAPER/reaper-kb.ini`

Each script is an `SCR` line ending in the absolute path REAPER executes:

```
SCR 4 0 RS<id> "Custom: CopyMarkers.lua" "/Users/…/Installationspaket/CopyMarkers.lua"
KEY 17 67 _RS<id> 0   # Main : Opt+C : … : Script: CopyMarkers.lua
```

To see what will really run:

```bash
grep -E '^SCR .*(CopyMarkers|Live BPM Analyzer|MIDI notes|Rename selected)' \
  "/Users/tobiaspehla/Library/Application Support/REAPER/reaper-kb.ini"
```

**Why this matters (learned the hard way):** until 2026-07-15 the four scripts were registered from four different folders — the package, a `X - … - Not Ready` WIP folder, and the plain Desktop. Copying to `REAPER/Scripts` and confirming with `cmp` looked like verification but proved nothing, because REAPER never loaded those copies. It only surfaced once the scripts gained shared modules (`steelblue_*.lua`), which the other folders did not have. Worse, `MIDI notes to project markers.lua` ran a Desktop copy that was a day old, so it "worked" while silently being the previous version.

Facts about `reaper-kb.ini`:

- **REAPER rewrites it on exit** — it must be closed before editing, or changes are lost.
- The `RS<id>` is **not** derived from the path (verified: it is not sha1 of the path in any obvious form). So the path can be edited in place and the `KEY` shortcut binding survives. Re-adding a script through the Action List instead mints a new id and **loses the shortcut**.
- The file is **CRLF**. Strip `\r` when parsing lines in shell, or extraction silently returns a path with a trailing quote.
- Back it up before touching it.

Current shortcuts: Copy Markers `Opt+C`, Live BPM Analyzer `Cmd+Shift+B`, MIDI notes `Cmd+Shift+H`, Rename selected markers `Cmd+Shift+N`.

The user works in German and expects practical, directly testable REAPER tools.

**The plugin UIs are English** (decided 2026-07-15). Talk to Tobi in German, write UI strings in English. The package was previously split — three German scripts with umlauts stripped ("Ausgewaehlte", "Schliessen") plus an English BPM Analyzer; all four are English now, so the umlaut workaround is gone and should not come back.

## Current Plugin Overview

### 1. MIDI notes to project markers

Files:

- `…/Reaper LD Plugins Installationspaket/MIDI notes to project markers.lua` — **the only live file**

Orphaned copies (nothing runs them; delete on sight): `~/Desktop/MIDI notes to project markers.lua` (this one was running as REAPER's registered script until 2026-07-15 and was a day stale), `~/Library/.../REAPER/Scripts/MIDI notes to project markers.lua`.

Current behavior:

- Creates project markers from MIDI note start positions.
- Supports:
  - all MIDI items in project
  - only selected MIDI items
- Handles looped MIDI items over visible item length.
- Has ReaImGui selection window with:
  - scope buttons
  - MA-Tools syntax checkbox
- MA syntax option formats markers like:
  - `C4(1)[Top]^C4^`
- Uses same random color for markers with the same original MIDI note/name.
- Window size was explicitly increased to avoid scrollbars.

Important implementation notes:

- ReaImGui context destruction must be guarded because this setup may not expose `ImGui_DestroyContext`.
- The marker color key should stay based on the original note name, not the formatted MA syntax string.

Status:

- Working and recently confirmed by user.

### 2. Copy Markers

Files:

- `…/Reaper LD Plugins Installationspaket/CopyMarkers.lua` — **the only live file**

Orphaned copies (nothing runs them; delete on sight): `…/X - Copy Markers - Not Ready/CopyMarkers.lua` (this WIP folder was REAPER's registered path until 2026-07-15, which is why Copy Markers was the one plugin that could not find the shared modules), `~/Library/.../REAPER/Scripts/CopyMarkers.lua`.

Current behavior:

- Copies marker data while preserving:
  - label
  - color
- **Selection comes from the Region/Marker Manager (rebuilt 2026-07-15).** The old "type marker IDs, leave empty for manager selection" `GetUserInputs` dialog is gone — the manager selection is now the only path, read **live every frame** via `steelblue_markers.lua`, so the window can stay open while markers are (de)selected.
- Has ReaImGui target dialog with:
  - `measure.beats`
  - `hh:mm:ss:ff`
  - `Copy to actual cursor position`
  - `Refresh from cursor`
- User can leave the window open and move the REAPER cursor before committing.
- Uses `SetProjectMarker4`/`AddProjectMarker2`-style color-aware logic.

Important implementation notes:

- ReaImGui cleanup is guarded for compatibility with the installed ReaImGui build.
- The previous offset/color issue was fixed.
- Copying always sorts by **timeline position** (`MARKERS.sorted_by_position`), never by click order — spacing is preserved relative to the earliest selected marker. This is why Copy Markers, unlike Rename, does not need `selection_order` and therefore works fine on the JS-less fallback path.

Status:

- Selection rebuild done, all 8 selection scenarios pass in the offline harness; **awaiting user test in REAPER.**

### 3. Rename selected markers

Files:

- `…/Reaper LD Plugins Installationspaket/Rename selected markers.lua` — **the only live file**

Orphaned copy (nothing runs it; delete on sight): `~/Library/.../REAPER/Scripts/Rename selected markers.lua`.

Current behavior:

- Operates on markers selected in the Region/Marker Manager.
- Ignores regions.
- Supports MA-Tools marker syntax assembly via GUI.
- Default placeholder-style behavior:
  - `MarkerName(1)[Top]^MarkerName^`
- `MarkerName` is a real placeholder for the existing marker name.
- GUI supports optional toggles for:
  - cue number
  - command
  - sequence name
  - sequence name equals cue name
- Supports:
  - `Create Multiple cues in timeline order?`
  - `How many cues`

Timeline-order behavior:

- The wrap logic is intentional:
  - if 6 markers are selected and `How many cues = 5`, numbering should be `1 2 3 4 5 1`
- This was fixed by preferring Region/Marker Manager selection order over plain project-position sorting.

Important implementation notes:

- On REAPER 7.62+, the script can read selected markers using `B_UISEL`.
- For correct cue numbering order, the current script prefers direct Region/Marker Manager list selection via JS_ReaScriptAPI when available and stores `selection_order`.
- Sorting must respect `selection_order` when present.

Status:

- Working and accepted by user.

### 4. Live BPM Analyzer

Files:

- `…/Reaper LD Plugins Installationspaket/Live BPM Analyzer.lua` — **the only live file**

Orphaned copies (nothing runs them; delete on sight): `…/X - BPMAnalyzer - Not Ready/Live BPM Analyzer.lua`, `~/Library/.../REAPER/Scripts/Live BPM Analyzer.lua`.

Current behavior:

- ReaImGui-based live BPM display.
- Designed for a finished song running as an audio item on a track.
- Reads audio samples via `CreateTakeAudioAccessor` and `GetAudioAccessorSamples`.
- Displays:
  - BPM with 2 decimal places
  - raw BPM
  - confidence
  - raw confidence
  - current project tempo
- Supports:
  - `Analyze now`
  - `Half`
  - `Double`
  - `Precision analyze` (long-span pass, see below)
  - `Live update` checkbox (auto-analysis every 0.75 s; auto-disabled after a precision pass so the result stays)
  - `Set project tempo`
  - `Clear`
- Shows an octave hint line when a half/double/three-quarter reading scores ≥75% as strong as the winner ("Octave: X also fits — use Half/Double").
- If no item is selected, it tries to find the audio item under the play cursor.

Estimation pipeline (rewritten 2026-07-14 for the sub-0.5 BPM accuracy target):

1. Onset envelope (energy flux, 11025 Hz, frame 512, hop 128).
2. Coarse search: multi-harmonic comb (lags at 1x/2x/3x the beat, weights 1/0.6/0.4) on a 2x-decimated envelope, 0.5 BPM grid, multiplied by a mild log-normal tempo prior centered at 120 BPM (breaks 65-vs-130 octave ties toward the musically likely tempo).
3. Fine: two-stage long-lag refinement on the full envelope — find the correlation peak at ~8 whole beats, then at the longest span that leaves 30% overlap, with parabolic peak interpolation; period = peak lag / beat count. Quantization/bias error is divided by the beat count, which is what yields ~0.01 BPM precision.
4. `Precision analyze` runs the same estimator on up to 120 s taken from the middle of the item (skips intro/outro) instead of the live window.

Confidence metric (reworked 2026-07-14 after the user asked why a correct result only showed 55%):

- `confidence = 0.5 × dominance + 0.25 × absolute + 0.25 × refine` (live mode additionally mixes in history stability).
- **dominance** = margin over the best *genuinely competing* tempo, found by `pick_rival()`. Two exclusions, both measured on real material:
  - anything within **±8%** of the winner is the same correlation hill, not a rival. The comb landscape of a real song is ONE broad peak ~25 BPM wide (measured on the Vanessa Mai song: smooth hill from ~120 to ~145, peak 131). The old rule ("best candidate ≥3 BPM away") therefore sampled its own flank at ~90% of the peak → dominance ~0.09 → confidence structurally capped at ~55% no matter how clear the beat. That was the whole bug. The ±8% choice sits on a plateau: the rival stays 102.5 BPM for any radius from 8% to 20%.
  - **octave relatives** (0.5/2/0.75/1.5/…×) describe the same beat grid and must not count against confidence in the *number* — the Half/Double buttons are the control for that. They are surfaced via the separate octave hint instead.
- **absolute** = `(comb_score − 0.45) / 0.35`. The floor is measured, not guessed: white noise still scores ~0.53 on the comb (the normalized correlation only accumulates over frames where the envelope is positive), so the old `/0.18` scale rated pure noise at 100% on this term.
- **refine** = `(refine_quality − 0.25) / 0.35` — long-lag peak height, the "is the pulse steady over minutes" signal. Rubato/drift collapse here.
- **Validated against positive AND negative controls** (`bpm_confidence_validate.lua`): real song 80% (precision) / 84% (60 s) / 71% (24 s live window), synthetic clean+busy mixes 90–92%, versus white noise 9%, ambient pad 7%, rubato sweep 110→150 BPM 10%. A confidence that is always high is as useless as one that is always 55% — keep the negative controls when touching this.

Accuracy guardrails learned during the rewrite (do not regress):

- The refinement search radius around the expected multi-beat lag must stay below 0.5 beat (currently 0.25): songs with offbeat hats have correlation peaks at half-beat multiples, and locking onto one skews the result by whole percents.
- A refinement peak at the search-window edge must be rejected (real peak lies outside → biased period).
- Verified with a synthetic-audio test harness (`bpm_accuracy_test.lua`, kick/snare/hat patterns with ±3 ms jitter at 10 known tempos, 24–120 s spans): max error 0.002 BPM; 174 BPM resolves to exactly 87.000 (half-time — `Double` gives the exact value). A second harness (`bpm_busy_test.lua`) uses dense "produced track" material (16th hats, 8th bass, pads, breakdowns): max error 0.004 BPM.
- **The DSP core is testable outside REAPER** via the `BPM_ANALYZER_TEST` global hook near the end of the script: set it to a table before `dofile`, and the script exports `sample_rate`/`hop_size`/`build_onset_envelope`/`estimate_bpm`/`comb_score`/`tempo_prior`/`decimate_envelope`/`refine_period` and skips the UI. Real audio can be fed in via `ffmpeg -i song.wav -ac 1 -ar 11025 -f f32le song.raw` and `string.unpack("<f", ...)`. This is by far the fastest way to debug this script — use it instead of guessing in REAPER.

Important safety behavior:

- `Set project tempo` currently includes a preservation pass intended to stop existing items from being stretched or shifted:
  - stores all item positions, lengths, snap offsets
  - stores active-take start offsets and playrates
  - stores item beat attach mode
  - temporarily forces project/item timebase to time
  - applies tempo
  - restores stored item values

Current status:

- Estimator rewritten 2026-07-14 (multi-harmonic comb + long-lag refinement + precision mode, see pipeline above).
- Synthetic-audio verification shows max error 0.002 BPM — well below the user's 0.5 BPM tolerance.
- **Verified against the user's real test song (Vanessa Mai TV edit, 193 s WAV):** the analyzer's precision pass reported 130.99; independent ground-truth measurement (beat-onset regression over 412 beats + phase-fold test on the decoded WAV) proved the song's true tempo is **130.974 BPM, not the 130.00** the user's previous analysis tool reported (integer rounding there; TV edits are commonly time-compressed by <1%). Analyzer error vs ground truth: **0.017 BPM**. The original complaint ("shows 131 for a 130 song") was a wrong reference tempo, not an analyzer error — but the rewrite still improved raw precision by two orders of magnitude.
- Lesson recorded: when the user reports a tempo mismatch, verify the reference tempo from the audio itself (beat-onset regression on the decoded file) before assuming detector error. Reference tempos from consumer DJ/analysis tools are usually rounded to whole BPM.
- `Set project tempo` behavior (item preservation pass) unchanged from the user-approved version.

## Shared modules (package-level, 2026-07-15)

Both live next to the scripts and are loaded via `debug.getinfo(1,"S").source` path resolution, guarded by `loadfile` so a missing file gives a sentence instead of a Lua traceback. **They must ship together with the scripts** — a lone .lua in the Scripts folder will refuse to start.

- **`steelblue_ui.lua`** — shared ReaImGui theme, used by **all four plugins** since 2026-07-15. Brand palette, `begin_window`/`end_window`, drawn logo mark (no asset file), section headings, big value display, meter, primary/secondary buttons, footer status strip. Verified by rendering against a fake `reaper` built from the real function list of the installed dylib (`ui_smoke_test.lua`) — that catches mistyped `ImGui_*` names, which otherwise only blow up on click in REAPER.
  - **Call pattern (important):** `end_window` must run on EVERY frame, including when the window is collapsed:
    ```lua
    local visible, open, font = SB.begin_window(ctx, TITLE, w, h)
    if visible then ... end
    SB.end_window(ctx, visible, font)   -- always
    ```
    ReaImGui differs from C++ Dear ImGui: `ImGui_End` belongs *only* in the `visible` branch (a collapsed window submits nothing), but the style stack must balance every frame regardless. Wrapping `end_window` inside `if visible` leaks the whole theme stack per frame. `ui_smoke_test.lua` runs 60 visible / 60 collapsed / 60 visible frames specifically to catch this.
  - **Windows auto-size to their content** (`WindowFlags_AlwaysAutoResize`, since 2026-07-15 — the fixed sizes gave every plugin a scrollbar). `begin_window(ctx, title, min_width)` — there is no height argument on purpose: every plugin reveals and hides rows at runtime (checkboxes unfolding fields, the BPM octave hint), so any fixed height is wrong eventually. Auto-size makes scrollbars structurally impossible instead of a number to keep re-guessing. `min_width` only prevents collapsing to the longest label.
  - **Never align an item to the right edge inside an auto-resizing window.** Its position comes from the current width, the width is then recomputed from the items, and the window shrinks a little more every frame. The header's "steelblue" wordmark and the footer's status text are therefore *drawn* (`SB.draw_text` → draw list), not submitted as items — decoration must not drive layout. For the same reason the footer reserves its height with `Dummy(1, h)`, never `Dummy(width, h)`.
  - **Layout is the one thing the offline harness cannot check** (the fake returns constant sizes). Same lesson as the jsdom coachmark episode in the D&D project: sizing/stacking bugs need a real render. The harness proves it does not crash; only REAPER proves it looks right.
- **`steelblue_markers.lua`** — Region/Marker Manager selection, the one job several plugins share. `selected()` returns `entries, reason, source`; `source` is `"manager"` (click order known) or `"arrange"` (unordered). Reason codes (`NO_API`/`MANAGER_CLOSED`/`NONE_SELECTED`) exist so callers can say something useful. Covered by `markers_test.lua` (8 scenarios: ordered selection, regions filtered out, manager closed, no JS extension, old REAPER, position sorting).

### Brand colors (measured, not guessed)

Sampled from `steelblue_final_rgb_black.blue.eps` / `..._cmyk_grey.blue.eps` (Illustrator EPS → embedded TIFF preview → raw RGB via `sips` + `ffmpeg`, sampled with Lua).

| Token | Value | Note |
| --- | --- | --- |
| Steel blue | `#4682B4` | **Area mean.** The EPS preview dithers the circle across 4 palette entries — a single-pixel read gives `#669ACD`, which is wrong. `#4682B4` is CSS "steelblue": the company name is its own hex value. |
| Grey | `#666666` | Flat, 100% of the region. |
| Black | `#000000` | Flat (RGB variant only). |

Use the **grey/blue** logo on REAPER's dark UI — the black wordmark disappears there.

### The drawn picture mark (`SB.logo_mark`)

Drawn with draw-list primitives, no asset file, so it stays crisp at any size. **Every constant is measured off the EPS, not eyeballed** (`measure_mark.lua`, `measure_lens.lua`), and verified by rasterising the same constants and diffing against the real logo pixel by pixel (`render_mark.lua`): currently **99.6 % of solid pixels match**.

Geometry: whole mark 618 × 545 → ratio **1.134, wider than tall**. Grey block spans 0 – 0.770 of the width, full height. Pupil centre (0.772, 0.499), radius 0.227 of the width, straddling the block's right edge. Lens outline is a circular arc, least-squares fitted over 219 boundary points (mean error 0.94 px): centre (1.07017, 1.10299), radius 1.04167 in units of mark **height**, from angle −1.76082 (block edge) to −2.52619 (tip), mirrored about the centre line.

Three mistakes made here, in order — do not repeat them:

1. **Drawn into a square.** Tobi's word was "squashed", and that was exactly right: forcing a 1.134 shape into 1.0.
2. **Quadratic bezier for the outline.** It cannot follow a circular arc; the lens opened ~2 % too wide at top and bottom.
3. **Circle fitted through three sample points.** It passed through those three and missed everywhere else — *worse* than the bezier (97.15 % vs 97.71 %). The assumption that broke it: the lens does **not** reach the top of the block. It starts at y = 0.08 of the height; above that the block is solid. Fitting all measured rows fixed it.

The lesson generalises: for anything traced from artwork, measure densely and diff the render against the source. "Looks about right" and "passes through my sample points" are both how you ship a wrong shape.

### REAPER / ReaImGui API facts worth keeping

- Installed ReaImGui is the **0.10 API** (Dear ImGui 1.92, dynamic fonts): `ImGui_PushFont(ctx, font, size)` takes a size. Old 2-arg font code crashes. Upside: one font object can be pushed at any size.
- `B_UISEL` is documented as **"selected in arrange view"** — that is *not* literally the Region/Marker Manager's list selection, and it carries no click order. Fine for Copy Markers (sorts by position), not fine for Rename's cue numbering.
- `EnumProjectMarkers3` / `SetProjectMarker3` are marked **"discouraged"** by REAPER; `GetNumRegionsOrMarkers` + `GetRegionOrMarker(proj, index, guidStr)` + `GetRegionOrMarkerInfo_Value(proj, regionOrMarker, param)` are the current API. Note `GetRegionOrMarker` returns a **pointer**, and its index counts markers AND regions — never mix it with an `EnumProjectMarkers3` index. Match by the displayed ID (`I_NUMBER`) instead. (`Rename selected markers.lua` still contains that index mix-up in its untested fallback — see Open Priorities.)
- Verifying against the binaries beats guessing: `strings` on `REAPER` / `reaper_imgui-*.dylib` lists every registered API name and its argument list.

## User Expectations

- The user prefers concrete, immediately usable tools over abstract discussion.
- REAPER GUI details matter a lot.
- Window sizing and button labeling should feel polished.
- MA-Tools syntax is central in the marker workflows.
- The user values preserving timeline/item integrity when changing project tempo.

## Technical Environment

- OS: macOS
- REAPER version visible in screenshots/conversation: `v7.75`
- ReaImGui is installed.
- Lua compiler (`luac`) is installed and should be used for syntax checking.
- JS_ReaScriptAPI is available and used by some scripts.

## Verification Habits

**The old workflow here told you to copy the edited script to `REAPER/Scripts` and confirm with `cmp`. That step was useless and actively misleading — REAPER runs the scripts straight out of the package folder. It has been removed.**

Current workflow:

1. edit the script in the package folder — this is the live file REAPER executes:
   - `/Users/tobiaspehla/Desktop/Plugin Factory/Reaper LD Plugins Installationspaket/...`
2. `luac -p "<file>"` — syntax only
3. run the offline harnesses below — this is the real check
4. no copying step: there is nothing to install. If a path ever needs to change, edit `reaper-kb.ini` with REAPER closed (see the section at the top).

Do not reintroduce mirror copies of the plugins. Every duplicate is a file that will silently rot and then get run by accident; that is exactly what happened on 2026-07-15.

### Offline harnesses (`tests/`) — use these before touching REAPER

`luac -p` only proves a file compiles. These run the real code:

- **`plugin_render_test.lua`** — loads each of the four plugin files against a fake `reaper`, captures their `defer` loop and renders **30 real frames** each, checking for errors, unknown API names, and leaks of the color/var/font/window/item-width stacks. This is the single most useful check after any UI edit.
- **`ui_smoke_test.lua`** — theme module alone, 60 visible / 60 collapsed / 60 visible frames (the End-branch trap above).
- **`markers_test.lua`** — 8 Region/Marker Manager selection scenarios.
- **`bpm_accuracy_test.lua`** / **`bpm_busy_test.lua`** / **`bpm_confidence_validate.lua`** — BPM DSP, via the `BPM_ANALYZER_TEST` hook.

The fake-`reaper` trick: build the ImGui function list from `strings` on the installed dylib, and have the fake return `nil` for any name not in it. A typo then fails the harness instead of surviving until a user clicks the button.

### Computer-use cannot click ReaImGui buttons — do not trust it (2026-07-15)

Synthetic clicks from the computer-use tools do **not** reliably reach ReaImGui window content. Screenshots, window dragging and REAPER's own native UI (menus, the Region/Marker Manager, the native ▼/× title bar of an ImGui window) all respond normally, so the window *looks* interactive — but the ImGui buttons inside mostly do not fire.

This cost an hour on 2026-07-15. The symptom read exactly like a bug: a button click appeared to do nothing, the status line never changed, and the window looked frozen. Two "fixes" were built for it (deferring project work until after the frame, throttling the manager poll) and **neither changed anything, because nothing was broken** — Tobi clicked the same button by hand and it worked instantly.

Rules that follow:

- **Never conclude "the plugin is broken" from computer-use clicks.** Verify with a human click first. One sentence from Tobi ("wenn ich es nutze funktioniert der button") outweighed a page of my own reasoning.
- Computer-use is good for: screenshots, arranging windows, driving REAPER's native UI, launching scripts via shortcuts. It is not a substitute for a user pressing a button in an ImGui window.
- The offline harness said the code path was fine and it was **right**; the real-world "evidence" contradicting it was the artefact. When a harness and a shaky observation disagree, distrust the observation.

Two changes survive from that detour, on their own merit rather than as fixes:

- Copy Markers polls the Region/Marker Manager every **150 ms** instead of every frame. `MARKERS.selected()` enumerates windows via JS_ReaScriptAPI and allocates a 1024-slot `new_array`; running that at 60 fps was wasteful regardless. **`Rename selected markers.lua` still polls per frame and should get the same treatment** (it calls `collect_selected_markers()` on every frame).
- Button handlers queue their work and run it after `end_window`, keeping REAPER project mutations out of the ImGui frame.

**A failing harness is not automatically right.** The first version of `ui_smoke_test.lua` reported a window-stack leak that was the *test's* wrong expectation (it counted `Begin` calls that legitimately need no `End`), not a code bug. Check which side is wrong before "fixing" the code.

## Demo project + tutorial screenshots (2026-07-15)

- **`Demo Project/steelblue_demo.RPP`** — the project the tutorial screenshots are shot in. Generated as a file rather than clicked together (`gen_demo.lua`), so it is exactly reproducible: track BEAT with a **synthetic** 128 BPM drum loop (`steelblue_demo_beat.wav`, also generated), track CUE MIDI, and five named markers (intro/verse/buildup/drop/break). Tobi has since made the MIDI notes a realistic cue pattern rather than one-note-per-beat.
  - **Deliberately no client material.** Tobi's real project (a Vanessa Mai TV edit) has the client name, his licence string and his finished lighting cues on screen — none of that belongs in tutorials that get handed to other people. Running `Rename selected markers` on it would also have overwritten real cues.
  - Nice side effect worth keeping: the analyzer reads **128.00 BPM at 95 %** off the generated beat, which makes the BPM tutorial self-verifying. Could ship as a practice project with the package.
- **`Tutorials/img/`** — 7 screenshots at 3024 px: `bpm-01-analyze`, `copy-01-selection`, `copy-02-result`, `rename-01-selection`, `rename-02-numbering`, `midi-01-window`, `midi-02-result`.
  - `rename-02-numbering.png` is the good one: 4 markers, "How many cues" = 3 → `Crash(1)`, `Crash(2)`, `Crash(3)`, `Crash(1)`. That is the wrap logic, self-explanatory in one picture.
  - `rename-01-selection.png` shows *unnamed* markers, so the preview reads `(1)[Top]` and the `MarkerName` placeholder does not explain itself. Reshoot with named markers if the tutorial needs it.
- **Claude cannot save screenshots to disk.** The screenshot tool only returns images into the chat, and `screencapture` from the shell fails: the shell runs under `claude-code/<version>/claude.app`, which is a *separate* TCC client from the granted `Claude.app` (visible as the lowercase `claude.app` entry, switched off, in Screen Recording). So: **Tobi shoots, Claude collects from the Desktop.** Do not spend time re-litigating this.

### Real finds from that session, worth keeping

- **The Region/Marker Manager swallows the script shortcut.** With focus in the manager, `Opt+C` did not open Copy Markers *and* cleared the marker selection — while still starting the script invisibly in the background (REAPER then reports "CopyMarkers.lua is running in background" on the next try). Click into the arrange first. **This belongs in the tutorials.**
- Clicking into the arrange does **not** lose the manager's selection — only its highlight, which macOS dims while the manager is unfocused. The plugin keeps reading it correctly.

## The installer (2026-07-15)

`steelblue_install.lua` runs **inside REAPER**; `build-dmg.sh` wraps the folder into `dist/steelblue-LD-Plugin-Set.dmg`. The .dmg is only packaging — the install itself has to happen in-process, because `AddRemoveReaScript` exists only there. Verified prior art: Tobi's old `ReaperRenameMarkersInstaller` was an .exe that installed the extensions and still had to tell users to "Load ReaScript..." by hand. That gap is the installer's whole reason to exist.

It uses plain `ShowMessageBox` / `GetUserInputs`, **never `steelblue_ui.lua`** — it exists for the case where ReaImGui is missing, so it cannot draw itself with ReaImGui.

### The shortcut API, and its one limitation

REAPER has **no way to set a key binding from a script**. What exists:

| API | |
| --- | --- |
| `SectionFromUniqueID(0)` | the Main section |
| `AddRemoveReaScript(add, sectionID, scriptfn, commit)` | registers — **returns the new command ID**. `commit=false` for all but the last call |
| `CountActionShortcuts(section, cmd)` | is a key already bound? |
| `DoActionShortcutDialog(hwnd, section, cmd, -1)` | opens REAPER's own dialog; the **user** presses the keys |
| `GetActionShortcutDesc(section, cmd, idx, ...)` | read back what they chose |
| `DeleteActionShortcut(section, cmd, idx)` | |

So the installer proposes a key and opens the dialog. **The tutorials must keep saying "suggested shortcut"** — the user types it and may well pick something else. The printed shortcuts are Tobi's own bindings.

### Extensions are placed, not shipped

The user downloads ReaImGui / JS_ReaScriptAPI themselves; the installer only moves the file into `UserPlugins/`. That sidesteps ReaImGui's LGPL obligations, sidesteps JS_ReaScriptAPI's unclear licence, and sidesteps the architecture trap (the dylibs here are **arm64 only**). Handled on the way: `lipo -archs` sanity check before copying, `xattr -d com.apple.quarantine` after (a browser-downloaded extension is quarantined and REAPER silently refuses it), and a clear "restart REAPER" — extensions load only at startup.

### Testing it

`tests/installer_test.lua` runs the installer against a fake REAPER: 8 flow scenarios (all four registered, exactly one `commit=true`, declining shortcuts, not nagging about existing ones, both missing-extension paths, an incomplete copy aborting before it touches anything, cancel doing nothing). It also greps every `reaper.*` name out of the installer and checks each against the REAPER binary — a typo there would otherwise surface halfway through a stranger's install.

## Open Priorities

1. **Nothing here has been run in REAPER yet.** The installer and the .dmg pass the offline harness, but no one has double-clicked the image, run `steelblue_install.lua`, or watched `DoActionShortcutDialog` come up. Test on a machine that does *not* already have the plugins registered — Tobi's REAPER has them bound from `reaper-kb.ini` already, which hides exactly the case the installer is for.
2. **Startup dependency check in the four plugins** — still open. Today they degrade silently: three fall back to plain dialogs, and Rename quietly renumbers wrongly without JS_ReaScriptAPI. The installer warns at install time, but a user who installs the extension later, or removes it, gets no word from the plugins themselves.
3. **Windows.** Untested, and the tutorials no longer claim it. The Lua is portable, but `install_extension()` shells out to `/usr/bin/lipo`, `/bin/cp` and `/usr/bin/xattr` — all macOS-only. `build-dmg.sh` is macOS-only by nature. Tobi has Windows builds of ReaPack/JS_ReaScriptAPI in `../ReaperRenameMarkersInstaller/` if that becomes real.
4. `rename-01-selection.png` shows unnamed markers, so the preview reads `(1)[Top]` and the `MarkerName` placeholder does not explain itself. Reshoot with named markers.
4. `Live BPM Analyzer.lua`: verified on synthetic tests (≤0.002 BPM) and on the user's real song (0.017 BPM vs measured ground truth). Awaiting user sign-off after the ground-truth finding (the song was 130.97, not 130 — see status above).
5. **`Rename selected markers.lua` should migrate to `steelblue_markers.lua`.** It currently carries its own copy of the selection logic containing a real bug: its `collect_selected_markers_from_region_api()` fallback feeds a `GetRegionOrMarker` index (counts markers AND regions) into `EnumProjectMarkers3` (indexes differently), so it can read the wrong marker. It has never run on Tobi's machine because JS_ReaScriptAPI is installed and the manager path always wins — which is exactly why it is worth fixing before the package ships to someone without it. The shared module resolves this by matching on `I_NUMBER`.
6. **Dependency declaration for the package:** ReaImGui is required by all four (the BPM Analyzer refuses to start without it; the others fall back to plain dialogs). JS_ReaScriptAPI is required in practice by Rename (without it the cue order silently degrades). Copy Markers now survives without JS on REAPER 7.62+. **SWS is not used by any script** — keep it out of the install instructions.
7. Keep `Set project tempo` behavior safe for existing project items.
8. Preserve the working state of the other scripts; they are currently in a good place.
