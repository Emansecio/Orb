#!/bin/zsh
# Draws the README's pictures again (docs/readme/): each screen offscreen, with made-up data and a model connected
# (`Orb --snapshot readme-<scene>`, see Sources/Orb/Views/ReadmeSnapshots.swift), then finished by readme-frame.swift.
# Nothing of yours is read or shown, and the Orb you have open is left alone.
#
#   ./scripts/readme-shots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

out=docs/readme
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

swift build --product Orb >/dev/null
orb="$(swift build --show-bin-path)/Orb"

# shot <scene> <file> [width height]: the scene at the window's size (points; the picture is twice that).
shot() {
  ORB_SNAPSHOT_WAIT=7 ORB_SNAPSHOT_WIDTH="${3:-1100}" ORB_SNAPSHOT_HEIGHT="${4:-760}" "$orb" --snapshot "$1" "$work/$2.png"
}
# frame <file> [readme-frame.swift options]
frame() {
  local name=$1; shift
  swift scripts/readme-frame.swift "$work/$name.png" "$out/$name.png" "$@"
}

echo "Desenhando as telas..."
shot readme-showcase app 1280 800 &
shot readme-permission permission 1000 600 &
shot readme-group-chat group &
shot readme-wizard-asking create &
shot readme-wizard-appearance appearance &
shot readme-routines routines &
shot readme-connectors-gallery connectors &
shot readme-quickask-reply quickask &
shot readme-settings-usage usage &
shot welcome welcome &
wait
"$orb" --render-orbs "$work/orbs.png"
"$orb" --render-icon "$out/icon.png" 512

echo "Acabamento..."
frame app --width 2400 --backdrop
frame permission --crop 0,30,2000,650
frame group --crop 0,0,2200,1180
frame create --crop 280,0,1640,1520 --width 1200
frame appearance --crop 280,0,1640,1520 --width 1200
frame routines --crop 100,30,2000,1260
frame connectors --crop 0,0,2200,1360
frame quickask --crop 48,48,680,720 --width 900
frame usage --crop 0,0,1250,1000 --width 1200
frame welcome --crop 561,0,1600,1520 --width 1200
frame orbs --width 1600

ls -lh "$out"
