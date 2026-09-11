<div align="center">
  <img src="Tutorials/mark.svg" alt="steelblue studios" width="72">
  <h1>REAPER LD Plugin Set</h1>
  <p><em>Four tools for cue programming in REAPER — for lighting designers who write their timecode cues as markers.</em></p>
  <p><strong>steelblue studios</strong></p>
</div>

---

If you build light shows to a timeline, you probably live in REAPER's markers: one marker per cue, named for your console. These four plugins take the tedious parts of that off your hands — finding the real tempo, turning a MIDI rhythm into cues, naming a whole block at once, and copying a block to where the music repeats.

1.1.0 was tested on macOS; Windows was tested for 1.0.0 and the changes since are platform-neutral Lua. REAPER 7.

## The plugins

| Plugin | What it does |
| --- | --- |
| **Live BPM Analyzer** | Reads the real tempo out of the audio to two decimals and sets the project tempo — without moving anything you have already placed. |
| **MIDI notes to project markers** | Turns a MIDI item into markers: one per note, named after the note and coloured to match the track. Write your cue rhythm as MIDI, get cues. |
| **Rename selected markers** | Builds MA-Tools cue names for a whole selection at once, with a live preview and cue numbering that wraps. |
| **Copy Markers** | Duplicates a block of markers somewhere else, keeping their spacing, names and colours. For the chorus that comes back later in the song. |

<div align="center">
  <img src="Tutorials/img/bpm-01-analyze.png" alt="Live BPM Analyzer" width="46%">
  &nbsp;
  <img src="Tutorials/img/copy-01a-window.png" alt="Copy Markers" width="46%">
</div>

## What's new in 1.1.2

- **Rename selected markers** — `-`/`+` buttons next to the cue number field step it down or up by one.

## What's new in 1.1.1

- **Rename selected markers** — "Also set colour" is on by default (a random colour per run; untick it to leave the marker colours alone).
- **Rename selected markers** — the Command field is a list: Go, Top, Flash (default Top). A selected marker that already carries another command keeps it, shown as a fourth entry until you pick one of the three.
- **MIDI notes to project markers** — the same Command list, default Top (was a free-text field with `GO`).

## What's new in 1.1.0

- **Rename selected markers** — three free-text fields (cue name, command, sequence name; leave one empty to skip it), a "Reset to defaults" button, and an optional colour (random or last used). Recognises existing MA-Tools syntax instead of wrapping it a second time, and keeps the marker's ruler lane.
- **MIDI notes to project markers** — one ruler lane per track (named after the track, without the `(12)`-style suffix), cue number by pitch rank, markers and lane coloured to match the track, a command field (default `GO`), an option to replace existing markers in these lanes, and a warning when two tracks share a name.
- **Copy Markers** — copies keep their ruler lane, and the target fields now follow the edit cursor.
- **Live BPM Analyzer** — live analysis no longer stalls playback (108 ms → 3 ms per update); after a seek or start, the window rebuilds from the cursor (up to 4 s for the first reading); the footer shows the analysis time.
- All four plugins now tell you on startup if ReaImGui or js_ReaScriptAPI is missing.

## Install

**Download the package for your system from the [latest release](../../releases/latest):**

- macOS → `steelblue-LD-Plugin-Set-macOS.dmg`
- Windows → `steelblue-LD-Plugin-Set-Windows.zip`

Needs REAPER 7.x; ruler lanes need REAPER 7.72 or newer.

Then, in REAPER — one step:

```
Actions  ▸  Show Action List  ▸  New action…  ▸  Load ReaScript…
```

Pick **`steelblue_install.lua`** from the package and run it. The installer copies the plugins into REAPER's own Scripts folder, registers all four as actions, offers you a keyboard shortcut for each, and — because REAPER only loads extensions at startup — offers to quit REAPER so the next launch has everything ready.

That is the whole install. Afterwards you can throw the package away.

> **Why a script and not an .exe / .pkg?** Only a script running *inside* REAPER can register an action or open the shortcut dialog (`AddRemoveReaScript` exists only in-process). An external installer could drop files in place but would still leave you to "Load ReaScript…" by hand — so the script does the job an installer can't.

### The two extensions — included, not downloaded

The plugins need two REAPER extensions, and **both are bundled** for every supported architecture:

- **ReaImGui** — draws all four plugin windows.
- **js_ReaScriptAPI** — lets *Rename selected markers* read the order of your selection in the Region/Marker Manager.

Neither ships with REAPER. The installer picks the right build for your machine and installs it only if it is missing — it **never overwrites or downgrades** an extension you already have, and if you manage extensions through [ReaPack](https://reapack.com), ReaPack stays in charge. Both are the authors' own unmodified builds under their own licenses; see [`extensions/NOTICE.txt`](extensions/NOTICE.txt).

### The one thing everybody trips over

Before starting a marker plugin from a shortcut, **click once into the arrange view.** While the Region/Marker Manager has keyboard focus it swallows the shortcut — the window never appears, and your marker selection gets cleared as well.

## Try it without a real show

The [`Demo Project/`](Demo%20Project) folder holds a small REAPER project — a beat at exactly 128 BPM, a MIDI item, and named markers — so you can follow every guide without touching a real show file.

## Guides

One page per plugin, with screenshots, under [`Tutorials/`](Tutorials) (open `index.html`), and the same guides as PDF in the package. There is also a short phone-format walkthrough of Copy Markers at [`Tutorials/video/`](Tutorials/video).

The guides and videos still show version 1.0. Where the window looks different (Rename's three text fields, MIDI's ruler lanes), the plugin is right and the guide is old; updated guides come with version 2.

## Building from source

```sh
./build-package.sh all      # both packages into dist/
./build-package.sh mac      # just the .dmg
./build-package.sh win      # just the .zip
```

The tests run in plain Lua, no REAPER required — they build fake `reaper` tables from the real API name lists:

```sh
for t in tests/*_test.lua; do lua "$t"; done
```

## License

steelblue studios code is [MIT](LICENSE). The two bundled extensions keep their own licenses (ReaImGui: LGPL-3.0, js_ReaScriptAPI: MIT) — see [`extensions/NOTICE.txt`](extensions/NOTICE.txt).
