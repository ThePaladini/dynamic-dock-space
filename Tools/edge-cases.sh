#!/bin/zsh
# Edge-case scenarios for Dynamic Dock Space with disposable test windows (DDS-T0 on the left display, DDS-T1 on the
# right). Each step is followed by `ctl state`, which checks the invariants. Usage: Tools/edge-cases.sh [scenario...]
cd "$(dirname "$0")/.."
B=build; LOG=build/edge-cases.log
dockL() { $B/glide 2600 900 700 1079 450 >/dev/null; }
dockR() { $B/glide 700 900 2700 1079 450 >/dev/null; }
away()  { $B/glide 1900 1079 1900 500 150 >/dev/null; }      # pointer up, away from the edges
settle() { sleep ${1:-1.6}; }
check() { $B/ctl state "$1" | tee -a $LOG; }
setup() {
  pkill -f "$B/testwin" 2>/dev/null; sleep 0.3
  # Dock to the right display first, so both windows start in a known state
  $B/ctl state x | grep -q "d49:R=85" || { dockR; settle 1.2; }
  PREFIX=DDS-T SECS=600 $B/testwin "0,30,1920,1050" "1920,30,1920,965" >/dev/null 2>&1 &
  settle 1.2; away
}
scenario() { echo "\n### $1" | tee -a $LOG; }

S1() { scenario "S1 baseline moves"; setup; dockL; settle; check "Dock→L"; dockR; settle; check "Dock→R"; }
S2() { scenario "S2 full screen on the display without the Dock"; setup
  $B/ctl fs DDS-T0 on; settle 2.5; check "T0 FS (L)"; $B/ctl fs DDS-T0 off; settle 2.5; check "T0 FS off"; }
S3() { scenario "S3 full screen on the Dock's display"; setup
  $B/ctl fs DDS-T1 on; settle 2.5; check "T1 FS (R, Dock)"; $B/ctl fs DDS-T1 off; settle 2.5; check "T1 FS off"; }
S4() { scenario "S4 Dock pulled onto a full-screen display, then exit full screen"; setup
  $B/ctl fs DDS-T0 on; settle 2.5; dockL; settle; check "Dock→L over FS"; away; settle 1.5; check "pointer away"
  $B/ctl fs DDS-T0 off; settle 2.5; check "T0 FS off"; }
S5() { scenario "S5 Dock onto full screen and back, then exit"; setup
  $B/ctl fs DDS-T0 on; settle 2.5; dockL; settle; check "Dock→L over FS"; dockR; settle; check "Dock→R"
  $B/ctl fs DDS-T0 off; settle 2.5; check "T0 FS off"; }
S6() { scenario "S6 full screen on both displays"; setup
  $B/ctl fs DDS-T0 on; settle 2.5; $B/ctl fs DDS-T1 on; settle 2.5; check "both FS"; dockL; settle; check "Dock→L"
  $B/ctl fs DDS-T0 off; settle 2.5; check "T0 FS off"; $B/ctl fs DDS-T1 off; settle 5; check "T1 FS off (+repair)"; }
S7() { scenario "S7 full screen where the Dock is, Dock moved away, exit"; setup
  $B/ctl fs DDS-T1 on; settle 2.5; dockL; settle; check "Dock→L"; $B/ctl fs DDS-T1 off; settle 5; check "T1 FS off (+repair)"; }
S8() { scenario "S8 minimized while the Dock moves"; setup
  $B/ctl min DDS-T1 on; settle 1.2; osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "Code") to true'
  dockL; settle; $B/ctl min DDS-T1 off; osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "testwin") to true'; settle 2; check "T1 restored after Dock→L"; }
S9() { scenario "S9 quick back-and-forth"; setup
  dockL; sleep 0.25; dockR; sleep 0.25; dockL; settle 2; check "L,R,L quickly"; dockR; sleep 0.1; dockL; sleep 0.1; dockR; settle 2; check "R,L,R very quickly"; }
S10() { scenario "S10 false edge touch (pointer leaves before the Dock moves)"; setup
  $B/glide 2600 900 700 1079 300 >/dev/null & sleep 0.42; kill %1 2>/dev/null; away; settle 2; check "touched L edge briefly"; }
S11() { scenario "S11 auto-hide toggled"; setup
  osascript -e 'tell application "System Events" to set autohide of dock preferences to true'; settle 2.5; check "autohide on"
  osascript -e 'tell application "System Events" to set autohide of dock preferences to false'; settle 2.5; check "autohide off"; }
S12() { scenario "S12 Dock moved during a full-screen transition"; setup
  $B/ctl fs DDS-T0 on; sleep 0.3; dockL; settle 3; check "Dock→L while T0 entering FS"; $B/ctl fs DDS-T0 off; sleep 0.3; dockR; settle 3; check "Dock→R while T0 leaving FS"; }

S13() { scenario "S13 tiled halves and a small floating window"; setup
  $B/ctl frame DDS-T0 0 30 960 1050; PREFIX=DDS-Tsmall SECS=120 $B/testwin "1200,200,500,400" >/dev/null 2>&1 & settle 1.2
  PREFIX=DDS-T2 SECS=120 $B/testwin "960,30,960,1050" >/dev/null 2>&1 & settle 1.2; away
  dockL; settle; check "Dock→L (T0 left half, T20 right half)"; $B/ctl state x >/dev/null
  osascript -e 'tell application "System Events" to get {position, size} of window "DDS-Tsmall0" of process "testwin"' 2>/dev/null | sed 's/^/   small window: /' | tee -a $LOG
  dockR; settle; check "Dock→R"; }
S14() { scenario "S14 full-screen Space left in the background (Ctrl-←) while the Dock moves"; setup
  $B/ctl fs DDS-T0 on; settle 2.5; $B/glide 900 500 960 540 100 >/dev/null
  osascript -e 'tell application "System Events" to key code 123 using control down'; settle 2; check "L back on desktop, T0 FS in background"
  dockL; settle; check "Dock→L"; dockR; settle; check "Dock→R"
  $B/glide 900 500 960 540 100 >/dev/null; osascript -e 'tell application "System Events" to key code 124 using control down'; settle 2
  $B/ctl fs DDS-T0 off; settle 2.5; check "T0 FS off"; }
S15() { scenario "S15 Dock on the left side of the screen"; setup
  osascript -e 'tell application "System Events" to set screen edge of dock preferences to left'; settle 2.5; check "edge=left"
  osascript -e 'tell application "System Events" to set screen edge of dock preferences to bottom'; settle 2.5; check "edge=bottom again"; }
S16() { scenario "S16 Dock size changed"; setup
  local ts=$(defaults read com.apple.dock tilesize)
  osascript -e 'tell application "System Events" to set dock size of dock preferences to 0.15'; settle 2.5; check "smaller Dock"
  defaults write com.apple.dock tilesize -int $ts; killall Dock; settle 3.5; check "size restored (tilesize $ts)"; }

S17() { scenario "S17 pointer brushes the bottom edge for ~40 ms"; setup
  local n=$(grep -c "prediction\] pointer" build/eng-current.log)
  $B/glide 2600 900 700 1079 300 >/dev/null & sleep 0.33; kill %1 2>/dev/null; away; settle 1.5
  check "brushed L edge"; echo "   early shrinks started: $(( $(grep -c "prediction\] pointer" build/eng-current.log) - n ))" | tee -a $LOG; }

: > $LOG
for s in ${=${*:-S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15 S16 S17}}; do $s; done
pkill -f "$B/testwin"
echo "\n$(grep -c '^OK' $LOG) OK, $(grep -c '^BAD' $LOG) BAD"
