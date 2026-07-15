Copy Markers - README

Copy Markers is a REAPER ReaScript for duplicating project markers to a new absolute position.
It keeps the original spacing, marker names, and marker colors.

Installation

1. Copy CopyMarkers.lua into your REAPER Scripts folder.
2. In REAPER open Actions > Show Action List.
3. Click New action... > Load ReaScript...
4. Select CopyMarkers.lua.

Usage

1. Run CopyMarkers.lua from the Action List or a shortcut.
2. Enter marker IDs such as:
   - 3
   - 1,3,5
   - 2-8
   - 2-8,11,14
3. Leave the marker ID field empty to use the markers selected in the Region/Marker Manager.
   This optional selection mode requires JS_ReaScriptAPI and an open Region/Marker Manager.
4. Choose the target position in the modeless target window.
   The window stays open, so you can move REAPER's edit cursor while it is visible.
   Available actions:
   - Copy measure.beats
   - Copy hh:mm:ss:ff
   - Copy to actual cursor position
   - Refresh from cursor
5. Accepted typed target examples:
   - 01:00:00:00
   - 00:01:24:12
   - 17.1
   - 17.1.00

Notes

- Only project markers are copied, not regions.
- Marker colors are preserved.
- Timecode is parsed with REAPER's own time parser, avoiding manual frame calculation drift.
- The actual cursor button uses the live edit cursor position and avoids timecode display rounding.
- Beat/bar positions are parsed through REAPER instead of assuming a fixed 4/4 grid.
- The modeless target window requires ReaImGui. If ReaImGui is missing, the script falls back to a simple target input popup.
- The first selected marker is placed at the target position; all other markers keep their original relative distance.
- If another marker already exists at the target position, REAPER will allow both markers to coexist.
