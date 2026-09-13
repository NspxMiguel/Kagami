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
#    regenerated on every build (see the risk note in the fix plan: this script must
#    not dirty the tree). `bash Tools/stamp-build.sh` alone, outside Xcode, still
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
#    at project-generation time at all.
#
# This runs as a postBuildScript — AFTER Xcode's own CodeSign step, not before it —
# and re-signs the bundle itself once it is done writing. That is deliberate, not
# an oversight: an earlier version ran this as a preBuildScript (before Compile/
# Link/CodeSign), reasoning that writing the file early would let Xcode's normal
# CodeSign phase seal it along with everything else. That held on a full build, but
# broke on the very next incremental build with zero source changes: Xcode's build
# graph has no file reference for this resource (see the exclude in project.yml), so
# its dependency analysis sees nothing to re-sign and skips CodeSign entirely — yet
# this script is `basedOnDependencyAnalysis: false` and still overwrote the file
# (new builtAt timestamp) underneath the seal computed on the previous build.
# `codesign --verify --deep --strict` then fails with "a sealed resource is missing
# or invalid", invisible in `simctl install`/`launch` (which don't enforce a strict
# seal check) but very much enforced by `xcrun devicectl device install app` on a
# physical Vision Pro. Running after CodeSign and re-signing ourselves, every time,
# sidesteps Xcode's dependency analysis altogether: we never rely on it deciding to
# re-run CodeSign for us.
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

  # Re-seal the bundle now that we changed a file inside it after CodeSign already
  # ran. Skip quietly when signing is off (CODE_SIGNING_ALLOWED=NO, e.g. some
  # analysis-only invocations) or when there is no identity to sign with yet.
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    resign_args=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY")
    if [[ -n "${CODE_SIGN_ENTITLEMENTS:-}" && -f "${CODE_SIGN_ENTITLEMENTS}" ]]; then
      resign_args+=(--entitlements "$CODE_SIGN_ENTITLEMENTS")
    fi
    /usr/bin/codesign "${resign_args[@]}" "$CODESIGNING_FOLDER_PATH"
    echo "re-signed $CODESIGNING_FOLDER_PATH after stamping BuildInfo.json"
  fi
fi
