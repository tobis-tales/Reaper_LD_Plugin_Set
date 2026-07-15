#!/bin/bash
# Build the shippable disk image.
#
# The .dmg is only the wrapper: familiar, double-clickable, and it keeps the
# folder together. The install itself is steelblue_install.lua, which runs
# inside REAPER — an external installer cannot register the actions (REAPER's
# AddRemoveReaScript only exists in-process), and hand-editing reaper-kb.ini
# from outside would mean rewriting the file that holds every one of the user's
# shortcuts, with REAPER forced shut. Not worth it.
#
# What deliberately does NOT ship: tests/, AGENTS.md, .git, build-dmg.sh.
# Those are how the package is made, not what it is.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="steelblue LD Plugin Set"
DMG="$REPO/dist/steelblue-LD-Plugin-Set.dmg"
STAGE="$(mktemp -d)/$NAME"

trap 'rm -rf "$(dirname "$STAGE")"' EXIT

mkdir -p "$STAGE" "$REPO/dist"

# --- what ships -------------------------------------------------------------

cp "$REPO/steelblue_install.lua" "$STAGE/"
cp "$REPO/steelblue_ui.lua" "$STAGE/"
cp "$REPO/steelblue_markers.lua" "$STAGE/"
cp "$REPO/Live BPM Analyzer.lua" "$STAGE/"
cp "$REPO/MIDI notes to project markers.lua" "$STAGE/"
cp "$REPO/Rename selected markers.lua" "$STAGE/"
cp "$REPO/CopyMarkers.lua" "$STAGE/"

cp -R "$REPO/Tutorials" "$STAGE/Tutorials"
rm -rf "$STAGE/Tutorials/pdf"          # the HTML guides are the ones to read on screen
cp -R "$REPO/Demo Project" "$STAGE/Demo Project"
rm -rf "$STAGE/Demo Project/peaks"

mkdir -p "$STAGE/Guides (PDF)"
cp "$REPO/Tutorials/pdf/"*.pdf "$STAGE/Guides (PDF)/"

# --- the note people actually read ------------------------------------------

cat > "$STAGE/START HERE.txt" <<'TXT'
steelblue studios — REAPER LD Plugin Set
========================================

Four tools for cue programming in REAPER:

   Live BPM Analyzer                reads the real tempo out of the audio
   MIDI notes to project markers    turns MIDI notes into markers
   Rename selected markers          builds MA-Tools cue names in bulk
   Copy Markers                     copies a block of markers elsewhere


INSTALL
-------

1. Copy this whole folder somewhere permanent — Documents, for example.
   Not the Desktop, not Downloads: the plugins run from where you put it,
   so if the folder moves later, REAPER loses them.

2. In REAPER:  Actions > Show Action List > New action... > Load ReaScript...
   Pick  steelblue_install.lua  from this folder and run it.

3. The installer registers all four plugins and offers to assign keyboard
   shortcuts. That is the only manual step there is.


BEFORE THAT: TWO EXTENSIONS
---------------------------

Neither ships with REAPER. The installer checks for both and can place a
file you have already downloaded.

   ReaImGui          needed by all four plugins.
   JS_ReaScriptAPI   needed by "Rename selected markers" to read the order
                     of your selection. Without it the cue numbering
                     silently follows plain timeline order instead.

The easy route for both is ReaPack:  https://reapack.com
Extensions are only loaded when REAPER starts — restart after installing.


THE ONE THING EVERYBODY TRIPS OVER
----------------------------------

Before starting a marker plugin from a shortcut, click once into the
arrange view. While the Region/Marker Manager has keyboard focus it
swallows the shortcut: the window never appears, and your marker
selection gets cleared as well.


WHAT ELSE IS IN HERE
--------------------

   Tutorials/       one guide per plugin, open index.html
   Guides (PDF)/    the same guides for printing or mailing
   Demo Project/    a small REAPER project to practise on:
                    a beat at exactly 128 BPM, a MIDI item, named markers
TXT

# --- pack -------------------------------------------------------------------

rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

echo "built: $DMG"
echo "  $(du -h "$DMG" | cut -f1)"
