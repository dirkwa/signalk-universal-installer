#!/usr/bin/env bash
# dev/new-wasm-plugin.sh — create a Rust WASM plugin under dev/plugins/
# from dev/templates/wasm-rust, ready for the dev server:
#
#   dev/new-wasm-plugin.sh signalk-my-plugin
#   dev/dev.sh restart        # builds it (first run) and links it
#
# The name becomes the npm package name and the plugin id. Scoped names
# (@scope/name) are refused: signalk-server 2.33.0 shows no status and
# reads no saved config for a WASM plugin with a scoped package name.
set -euo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${DEV_DIR}/templates/wasm-rust"
PLUGINS_DIR="${DEV_DIR}/plugins"

usage() {
  echo "usage: $0 <plugin-name>   e.g. signalk-anchor-alarm" >&2
  echo "  two or more words of lowercase letters and digits, joined by hyphens" >&2
  exit 1
}

[ "$#" -eq 1 ] || usage
name="$1"
# At least two words: the crate name (hyphens -> underscores) can then
# never be a Rust keyword or a reserved crate name such as `test`.
[[ "${name}" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)+$ ]] || usage

target="${PLUGINS_DIR}/${name}"
if [ -e "${target}" ]; then
  echo "==> ${target} already exists — not overwriting it" >&2
  exit 1
fi

crate="${name//-/_}"
# signalk-my-plugin -> "Signalk My Plugin", a starting point for the
# name shown in the admin UI.
display=""
IFS='-' read -r -a words <<< "${name}"
for word in "${words[@]}"; do
  display+="${display:+ }${word^}"
done

mkdir -p "${PLUGINS_DIR}"
cp -r "${TEMPLATE_DIR}" "${target}"
while IFS= read -r -d '' file; do
  sed -i \
    -e "s/__PLUGIN_ID__/${name}/g" \
    -e "s/__CRATE_NAME__/${crate}/g" \
    -e "s/__DISPLAY_NAME__/${display}/g" \
    "${file}"
done < <(find "${target}" -type f -print0)

echo "==> Created ${target}"
if ! command -v cargo >/dev/null 2>&1; then
  echo "==> NOTE: cargo is not on PATH. The Rust devcontainer variant"
  echo "    (signalk devpod rust up) ships the toolchain; elsewhere install"
  echo "    rustup and run: rustup target add wasm32-wasip1"
fi
echo "    Build and load it:  dev/dev.sh restart"
echo "    After code changes: SK_DEV_PLUGIN_BUILD=1 dev/dev.sh restart"
