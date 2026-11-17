#!/usr/bin/env bash
# docs/MANUAL.md -> docs/MANUAL.pdf (A4, images embedded).
# Pandoc renders the HTML and a headless Chrome prints it; both run as
# containers (podman or docker), so nothing needs to be installed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=$(command -v podman || command -v docker)
WORK=$(mktemp -d)
chmod 777 "$WORK"
cp -R "$ROOT/docs/img" "$WORK/img"
cp "$ROOT/tools/pdf/manual.css" "$WORK/"
# drop the in-document title (the cover has it) and the GitHub-only image note
sed -e '1{/^# /d}' "$ROOT/docs/MANUAL.md" >"$WORK/manual.md"
cat >"$WORK/cover.html" <<HTML
<div class="cover"><div class="k">Vision Intelligence</div><h1>Rekognitor</h1>
<p>Manual de instalação</p><p>Windows · Linux · macOS</p>
<div class="meta">Versão de $(date '+%d/%m/%Y') · github.com/Rekognitor/rekognitor-setup</div></div>
HTML
"$ENGINE" run --rm -v "$WORK:/w:Z" -w /w docker.io/pandoc/core:3.6 manual.md \
  -f gfm -t html5 -s --no-highlight --embed-resources --css manual.css -B cover.html \
  --metadata title="Rekognitor — Manual de instalação" --metadata lang=pt-BR -o manual.html
# pandoc's default template prints the title block: the cover replaces it
sed -i 's#<header id="title-block-header">.*</header>##; /<header id="title-block-header">/,/<\/header>/d' "$WORK/manual.html"
"$ENGINE" run --rm -v "$WORK:/w:Z" docker.io/zenika/alpine-chrome:124 --no-sandbox \
  --no-pdf-header-footer --print-to-pdf=/w/manual.pdf file:///w/manual.html >/dev/null 2>&1
cp "$WORK/manual.pdf" "$ROOT/docs/MANUAL.pdf"
rm -rf "$WORK"
echo "docs/MANUAL.pdf ($(du -h "$ROOT/docs/MANUAL.pdf" | cut -f1))"
