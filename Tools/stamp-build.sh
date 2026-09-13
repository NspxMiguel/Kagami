#!/bin/bash
# Writes Sources/Resources/BuildInfo.json with the commit this build was made from.
#
# Runs as a preBuildScript (see project.yml) so every build — device, simulator, or
# CI — carries a stamp of exactly what was built. Without this nobody can tell which
# commit produced the app on the headset versus what is on disk right now.
#
# The output file is gitignored and regenerated on every build. It still has to
# exist on disk the first time `xcodegen generate` runs, because xcodegen only adds
# files it can see to the Xcode project: on a fresh checkout, run this script once
# before the first `xcodegen generate`.
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

out="Sources/Resources/BuildInfo.json"
mkdir -p "$(dirname "$out")"
cat > "$out" <<JSON
{
  "commit": "$commit",
  "dirty": $dirty,
  "builtAt": "$built_at"
}
JSON

echo "stamped $out: commit=$commit dirty=$dirty builtAt=$built_at"
