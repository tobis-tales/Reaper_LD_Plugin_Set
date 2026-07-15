#!/bin/bash
# Build the shippable packages: a .dmg for macOS, a .zip for Windows.
#
# Both wrap the SAME thing — steelblue_install.lua, which runs inside REAPER.
# The wrapper is only a delivery format. An external installer (a .exe, a .pkg)
# cannot do the actual job: REAPER's AddRemoveReaScript only exists in-process,
# so nothing outside REAPER can register the actions or open the shortcut
# dialog. Tobi's own 2025 Windows installer proves the point — it bundled
# ReaPack, SWS and js_ReaScriptAPI, and its readme still had to end with "now
# open the Action List and Load ReaScript by hand". That step is exactly what
# the Lua installer removes, so wrapping it in an .exe would only add an
# unsigned-binary warning and take nothing away.
#
# Usage:  ./build-package.sh [mac|win|all]      (default: all)
#
# What deliberately does NOT ship: tests/, AGENTS.md, .git, build scripts,
# Tutorials/video/work/. Those are how the package is made, not what it is.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="steelblue LD Plugin Set"
WHAT="${1:-all}"

mkdir -p "$REPO/dist"

# --- staging, shared by both platforms ---------------------------------------
# $1 = root dir to fill, $2 = "macOS" | "Windows" (which extensions/ to include)

stage_payload() {
  local root="$1" platform="$2"
  local inner="$root/steelblue Plugin Set"
  mkdir -p "$inner"

  cp "$REPO/steelblue_install.lua"              "$inner/"
  cp "$REPO/steelblue_ui.lua"                   "$inner/"
  cp "$REPO/steelblue_markers.lua"              "$inner/"
  cp "$REPO/Live BPM Analyzer.lua"              "$inner/"
  cp "$REPO/MIDI notes to project markers.lua"  "$inner/"
  cp "$REPO/Rename selected markers.lua"        "$inner/"
  cp "$REPO/CopyMarkers.lua"                    "$inner/"

  cp -R "$REPO/Tutorials" "$inner/Tutorials"
  rm -rf "$inner/Tutorials/pdf"            # the HTML guides are the on-screen ones
  rm -rf "$inner/Tutorials/video/work"     # slide/clip intermediates, rebuildable
  cp -R "$REPO/Demo Project" "$inner/Demo Project"
  rm -rf "$inner/Demo Project/peaks"

  mkdir -p "$inner/Guides (PDF)"
  cp "$REPO/Tutorials/pdf/"*.pdf "$inner/Guides (PDF)/"

  # Only this platform's binaries: shipping the other one's would double the
  # download for something the installer would never look at.
  mkdir -p "$inner/extensions/$platform"
  cp "$REPO/extensions/$platform/"* "$inner/extensions/$platform/"
  cp "$REPO/extensions/NOTICE.txt" "$REPO/extensions/LICENSE-"*.txt "$inner/extensions/"

  # The installer also sits at the top, next to the note: it is the one thing
  # people need to find. It resolves the payload one folder down by itself.
  cp "$REPO/steelblue_install.lua" "$root/"
}

# --- the note people actually read -------------------------------------------
# $1 = root dir, $2 = "mac" | "win"

write_readme() {
  local root="$1" flavour="$2" wrapper builds discard

  if [ "$flavour" = mac ]; then
    wrapper="disk image"
    builds="macOS (Apple Silicon and Intel)"
    discard="eject and delete this disk image"
  else
    wrapper="folder"
    builds="Windows (64-bit and 32-bit)"
    discard="delete this folder"
  fi

  cat > "$root/READ ME FIRST.txt" <<TXT
steelblue studios — REAPER LD Plugin Set
========================================

Four tools for cue programming in REAPER:

   Live BPM Analyzer                reads the real tempo out of the audio
   MIDI notes to project markers    turns MIDI notes into markers
   Rename selected markers          builds MA-Tools cue names in bulk
   Copy Markers                     copies a block of markers elsewhere


HOW TO INSTALL — one step
-------------------------

In REAPER:

   Actions  >  Show Action List  >  New action...  >  Load ReaScript...

Pick  steelblue_install.lua  — it is right here next to this note.

That is it. The installer copies the plugins into REAPER's own Scripts
folder, registers all four as actions, and lets you assign a keyboard
shortcut to each. Afterwards you can $discard —
REAPER will not need it again.


TWO EXTENSIONS ARE NEEDED — AND THEY ARE INCLUDED
-------------------------------------------------

   ReaImGui          needed by all four plugins.
   js_ReaScriptAPI   needed by "Rename selected markers" to read the order
                     of your selection. Without it the cue numbering
                     silently follows plain timeline order instead.

Neither ships with REAPER, so both are bundled here for $builds.
The installer picks the right build for your machine and offers to
install it — nothing is downloaded.

If you already have one of them, the installer leaves it strictly alone.
It never overwrites or downgrades what you have; if you manage extensions
through ReaPack, ReaPack stays in charge.

They are the authors' own unmodified builds, shipped under their own
licences. See  steelblue Plugin Set/extensions/NOTICE.txt  for versions,
licences and where the source lives.

REAPER loads extensions only when it starts. If the installer places one,
it will offer to quit REAPER for you — open it again and everything is
there.


THE ONE THING EVERYBODY TRIPS OVER
----------------------------------

Before starting a marker plugin from a shortcut, click once into the
arrange view. While the Region/Marker Manager has keyboard focus it
swallows the shortcut: the window never appears, and your marker
selection gets cleared as well.


WHAT IS IN THE $(echo "$wrapper" | tr '[:lower:]' '[:upper:]')
---------------------$(echo "$wrapper" | sed 's/./-/g')

   steelblue_install.lua   the installer — start here
   Tutorials/              one guide per plugin, open index.html
   Guides (PDF)/           the same guides for printing or mailing
   Demo Project/           a small REAPER project to practise on:
                           a beat at exactly 128 BPM, a MIDI item,
                           and named markers
TXT
}

# --- macOS: disk image --------------------------------------------------------

build_mac() {
  local tmp root dmg
  tmp="$(mktemp -d)"
  root="$tmp/$NAME"
  dmg="$REPO/dist/steelblue-LD-Plugin-Set-macOS.dmg"
  mkdir -p "$root"

  stage_payload "$root" "macOS"
  write_readme "$root" mac

  rm -f "$dmg"
  hdiutil create -volname "$NAME" -srcfolder "$root" -ov -format UDZO -quiet "$dmg"
  rm -rf "$tmp"

  echo "built: $dmg"
  echo "  $(du -h "$dmg" | cut -f1)"
}

# --- Windows: zip -------------------------------------------------------------

build_win() {
  local tmp root zip
  tmp="$(mktemp -d)"
  root="$tmp/$NAME"
  zip="$REPO/dist/steelblue-LD-Plugin-Set-Windows.zip"
  mkdir -p "$root"

  stage_payload "$root" "Windows"
  write_readme "$root" win

  rm -f "$zip"
  # -X drops the resource forks and .DS_Store noise that macOS zip otherwise
  # buries in the archive, where they would show up as junk on a Windows PC.
  ( cd "$tmp" && zip -q -r -X "$zip" "$NAME" -x '*.DS_Store' )
  rm -rf "$tmp"

  echo "built: $zip"
  echo "  $(du -h "$zip" | cut -f1)"
}

case "$WHAT" in
  mac) build_mac ;;
  win) build_win ;;
  all) build_mac; build_win ;;
  *)   echo "usage: $0 [mac|win|all]" >&2; exit 2 ;;
esac
