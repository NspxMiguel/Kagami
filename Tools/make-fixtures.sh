#!/bin/bash
# Generates realistic H.264 test fixtures with ffmpeg.
#
# The checked-in fixture (keyframe.h264) is one repeated keyframe, which cannot show
# the keyframe-wait freeze or the burst-catch-up behavior described in the fix plan —
# both only appear with a GOP longer than a second and genuine motion between frames.
# This produces a fixture close to what the real console sends: a long IDR interval
# and enough entropy per frame that P-frames are a meaningful size, not a near-empty
# skip block.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/Tests/KagamiCoreTests/Fixtures"
out="$out_dir/busy-gop150.h264"

command -v ffmpeg >/dev/null 2>&1 || {
  echo "ffmpeg not found on PATH" >&2
  exit 1
}

mkdir -p "$out_dir"

# 10 s at 1280x720/30 fps = 300 frames. GOP 150 gives exactly 2 IDRs, the same
# interval (5 s) Tools/fake-console.py's --gop 150 default reproduces live.
ffmpeg -y -loglevel error \
  -f lavfi -i "testsrc2=size=1280x720:rate=30,noise=alls=60:allf=t" \
  -t 10 \
  -c:v libx264 -profile:v main -preset ultrafast -tune zerolatency \
  -g 150 -pix_fmt yuv420p \
  -b:v 6000k -maxrate 6000k -bufsize 6000k \
  -x264-params "slices=1:sliced-threads=0" \
  -bsf:v dump_extra \
  -f h264 "$out"

size=$(du -h "$out" | cut -f1)
echo "wrote $out ($size)"
