#!/usr/bin/env bash
# Turn captured terminal logs into the PNG "prints" used by docs/MANUAL.md.
#
#   tools/screenshots.sh LOG OUT.png "Window title" [bash|powershell] ["command shown"]
#
# Renders LOG with tools/render-terminal.py and screenshots it with a headless
# Chrome container (podman or docker). Logs come from real runs: the CI artifact
# "linux-logs" (install/uninstall), or a local `script -qec "./install.sh --check" /dev/null`.
set -euo pipefail
LOG=${1:?log} OUT=${2:?out.png} TITLE=${3:-Terminal} THEME=${4:-bash} CMD=${5:-}
HERE=$(cd "$(dirname "$0")" && pwd)
ENGINE=$(command -v podman || command -v docker)
WORK=$(mktemp -d)
chmod 777 "$WORK"
size=$(python3 "$HERE/render-terminal.py" "$LOG" "$WORK/shot.html" --title "$TITLE" --theme "$THEME" --cmd "$CMD")
"$ENGINE" run --rm -v "$WORK:/w:Z" docker.io/zenika/alpine-chrome:124 --no-sandbox --hide-scrollbars \
  --screenshot=/w/shot.png --window-size="$size" --default-background-color=00000000 file:///w/shot.html >/dev/null 2>&1
cp "$WORK/shot.png" "$OUT"
rm -rf "$WORK"
echo "$OUT ($size)"
