#!/bin/bash
# Writes BuildInfo.json with the commit this build was made from.
#
# Runs as a preBuildScript (see project.yml) so every build — device, simulator, or
# CI — carries a stamp of exactly what was built. Without this nobody can tell which
# commit produced the app on the headset versus what is on disk right now.
#
# Two copies are written, because they serve two different readers:
#
# 1. Sources/Resources/BuildInfo.json — the source-tree copy. It is gitignored and
#    regenerated on every build (see the risk note in the fix plan: a preBuildScript
#    must not dirty the tree). `bash Tools/stamp-build.sh` alone, outside Xcode, still
#    produces this file, which is what the plan's acceptance check and any tooling
#    that just wants the commit string reads.
#
# 2. Straight into the built product's resource folder ($CODESIGNING_FOLDER_PATH),
#    when run as an Xcode build phase. This is the one BuildInfo.swift's
#    `Bundle.main.url(forResource:withExtension:)` actually reads at runtime, and it
#    is written directly rather than relying on Xcode's Copy Bundle Resources phase,
#    because that phase only copies files xcodegen already knew about when
#    `xcodegen generate` last ran. On a fresh clone, BuildInfo.json does not exist
#    yet the first time `xcodegen generate` runs (nothing has stamped it), so
#    xcodegen has no file reference for it, no Copy Bundle Resources step is ever
#    created for it, and no later run of this script can retroactively add one — the
#    stamp would silently never appear in the app. Writing directly into the product
#    folder sidesteps that: it does not depend on the file existing, or on xcodegen,
#    at project-generation time at all. This preBuildScript runs before Compile
#    Sources and well before CodeSign, so the file is present when the bundle gets
#    signed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

commit=$(git rev-parse --short HEAD)
if git diff --quiet && git diff --cached --quiet; then
  dirty=false
else
  dirty=true
fi
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

json=$(cat <<JSON
{
  "commit": "$commit",
  "dirty": $dirty,
  "builtAt": "$built_at"
}
JSON
)

source_copy="Sources/Resources/BuildInfo.json"
mkdir -p "$(dirname "$source_copy")"
printf '%s\n' "$json" > "$source_copy"
echo "stamped $source_copy: commit=$commit dirty=$dirty builtAt=$built_at"

# CODESIGNING_FOLDER_PATH is only set when Xcode runs this as a build phase (it is
# the full path to the .app about to be signed, e.g. .../Kagami.app — visionOS/iOS
# bundles are flat, so this is also the resources root, unlike macOS's Contents/
# Resources layout).
if [[ -n "${CODESIGNING_FOLDER_PATH:-}" ]]; then
  product_copy="$CODESIGNING_FOLDER_PATH/BuildInfo.json"
  printf '%s\n' "$json" > "$product_copy"
  echo "stamped $product_copy: commit=$commit dirty=$dirty builtAt=$built_at"
fi
