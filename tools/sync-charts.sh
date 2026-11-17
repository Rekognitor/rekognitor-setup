#!/usr/bin/env bash
# Copy the Helm charts from the (private) rekognitor.helm repository into charts/,
# stripping the secrets this public repository must not carry. The installer
# generates fresh secrets for every installation (~/.rekognitor/secrets).
#
#   tools/sync-charts.sh /path/to/rekognitor.helm
set -euo pipefail
SRC=${1:?uso: tools/sync-charts.sh /caminho/para/rekognitor.helm}
DST=$(cd "$(dirname "$0")/.." && pwd)/charts
[[ -d $SRC/helm-charts ]] || { echo "não achei $SRC/helm-charts" >&2; exit 1; }

rm -rf "$DST"
mkdir -p "$DST"
# triton is left out: its image is not on Docker Hub (see rekognitor.helm ci/README.md)
for dir in "$SRC"/helm-charts/*/; do
  name=$(basename "$dir")
  [[ $name == triton ]] && continue
  cp -R "$dir" "$DST/$name"
done
rm -rf "$DST"/*/scripts # WSL helpers of the dev setup; the installer has its own

# secrets -> placeholders (install.sh always overrides them with --set)
sed -i.bak -E \
  -e 's/^(  CLIENT_ID: ).*/\1"set-by-installer"/' \
  -e 's/^(  SECRET: ).*/\1"set-by-installer"/' \
  "$DST/streamer/values.yaml"
sed -i.bak -E 's/^(  authSecret: ).*/\1"set-by-installer"/' "$DST/mqtt/values.yaml"
find "$DST" -name '*.bak' -delete

# every secret field must now hold the placeholder
for f in "streamer/values.yaml:  CLIENT_ID" "streamer/values.yaml:  SECRET" "mqtt/values.yaml:  authSecret"; do
  grep -qE "^${f#*:}: \"set-by-installer\"$" "$DST/${f%%:*}" || { echo "segredo não removido: $f - abortando" >&2; exit 1; }
done
echo "charts sincronizados de $SRC ($(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '?')):"
ls "$DST"
