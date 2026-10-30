#!/usr/bin/env bash
# Make the README screenshots in docs/screenshots, with made-up data only.
#
# Each state runs `Brah --demo <state>`, which draws a fake app with fake bills behind the real
# bubble and pointer. Only that scene is captured (or only the Settings window), never the rest
# of the screen. Needs a built app: scripts/bundle.sh. Screen Recording for the terminal.
set -euo pipefail

cd "$(dirname "$0")/.."
app="build/Brah.app/Contents/MacOS/Brah"
out="docs/screenshots"
[ -x "$app" ] || { echo "Build the app first: scripts/bundle.sh" >&2; exit 1; }
mkdir -p "$out"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for state in listening typing thinking answer approval handsfree settings; do
  : > "$log"
  "$app" --demo "$state" > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 40); do grep -q "demo frame\|demo window" "$log" && break; sleep 0.25; done
  # Let the bubble size itself and the waveform move.
  sleep 1.5

  if line=$(grep -m1 "demo window" "$log"); then
    screencapture -x -l "${line##* }" "$out/$state.png"
  else
    read -r x y w h <<< "$(grep -m1 "demo frame" "$log" | awk '{print $4, $5, $6, $7}')"
    screencapture -x -R "$x,$y,$w,$h" "$out/$state.png"
  fi
  kill "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true
  sips -Z 1600 "$out/$state.png" > /dev/null
  echo "Made $out/$state.png"
done
