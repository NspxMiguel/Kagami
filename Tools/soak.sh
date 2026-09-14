#!/usr/bin/env bash
#
# Drives one long-running soak of Kagami against Tools/fake-console.py on a booted
# visionOS Simulator, entirely outside any interactive conversation turn: everything
# from "boot the simulator" to "write the summary JSON" happens in this one process,
# so a soak can run in the background and be picked back up later just by waiting on
# its output file.
#
# Usage:
#   Tools/soak.sh --udid <UDID> --duration <SECONDS> --label <NAME> \
#       [--app <PATH TO .app>] [--extra-args "-flag value ..."]
#
# Writes build/soak-<label>.json when done. Exits non-zero only on a usage error or a
# failure to even get the app installed/launched — a crash or freeze *during* the soak
# is not a script failure, it is the measurement, and is recorded in the JSON.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.kagami.app"
VIDEO_PORT=9911
AUDIO_PORT=9922

UDID=""
DURATION=""
LABEL=""
APP_PATH=""
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --app) APP_PATH="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$UDID" || -z "$DURATION" || -z "$LABEL" ]]; then
  echo "usage: soak.sh --udid <UDID> --duration <SECONDS> --label <NAME> [--app <PATH>] [--extra-args \"...\"]" >&2
  exit 2
fi

mkdir -p build
OUT_JSON="build/soak-${LABEL}.json"
CONSOLE_LOG="build/soak-${LABEL}-console.log"
DIAG_LOG="build/soak-${LABEL}-diagnostics.log"
RSS_LOG="build/soak-${LABEL}-rss.csv"
: > "$RSS_LOG"

log() { echo "[soak $LABEL] $(date '+%H:%M:%S') $*"; }

# --- 0. Snapshot what already exists so we only ever attribute *new* things to this
#        run. A stale .ips from an earlier investigation (or another session) must
#        never be misread as this soak's crash.
REPORTS_DIR="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$REPORTS_DIR"
BEFORE_IPS="$(mktemp)"
find "$REPORTS_DIR" -maxdepth 1 -iname "Kagami-*.ips" 2>/dev/null | sort > "$BEFORE_IPS"

# --- 1. Build once, unless a prebuilt .app was handed to us.
if [[ -z "$APP_PATH" ]]; then
  if pgrep -x xcodebuild >/dev/null; then
    log "another xcodebuild is running on this Mac — waiting for it before starting ours"
    while pgrep -x xcodebuild >/dev/null; do sleep 5; done
  fi
  log "generating project and building for the visionOS Simulator"
  xcodegen generate >/dev/null
  if ! xcodebuild -project Kagami.xcodeproj -scheme Kagami \
      -destination "generic/platform=visionOS Simulator" \
      -derivedDataPath build build \
      > "build/soak-${LABEL}-xcodebuild.log" 2>&1; then
    log "BUILD FAILED — see build/soak-${LABEL}-xcodebuild.log"
    exit 1
  fi
  APP_PATH="$(find build/Build/Products -maxdepth 1 -iname 'Debug-xrsimulator' -o -iname 'Release-xrsimulator' 2>/dev/null | while read -r d; do find "$d" -maxdepth 1 -iname 'Kagami.app'; done | head -1)"
  if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$(find build/Build/Products -maxdepth 2 -iname 'Kagami.app' | head -1)"
  fi
fi
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  log "could not locate a built Kagami.app"
  exit 1
fi
log "using app at $APP_PATH"

# --- 2. Make sure the target simulator is booted, then install.
STATE="$(xcrun simctl list devices | grep "$UDID" | grep -oE '\(Booted\)|\(Shutdown\)' || true)"
BOOTED_BY_US=0
if [[ "$STATE" != "(Booted)" ]]; then
  log "booting simulator $UDID"
  xcrun simctl boot "$UDID"
  BOOTED_BY_US=1
  xcrun simctl bootstatus "$UDID" -b
fi

log "installing app"
xcrun simctl install "$UDID" "$APP_PATH"

# --- 3. Start the fake console. --seconds is the length of the clip it loops, kept
#        comfortably longer than this soak so we never cross fake-console.py's own
#        loop point mid-run and confuse that with a Kagami defect.
FAKE_SECONDS=$((DURATION + 120))
log "starting fake console for ${FAKE_SECONDS}s of clip (soak duration ${DURATION}s)"
python3 Tools/fake-console.py --gop 150 --motion noise --stall-ms 800 --stall-every 5 \
    --seconds "$FAKE_SECONDS" > "$CONSOLE_LOG" 2>&1 &
FAKE_PID=$!

# Wait for it to actually be listening before launching the app — belt and suspenders
# on top of fake-console.py's own listen-before-ffmpeg fix, since ffmpeg still takes
# real wall-clock time to build a multi-hundred-second clip.
for _ in $(seq 1 120); do
  if ! kill -0 "$FAKE_PID" 2>/dev/null; then
    log "fake-console.py exited early — see $CONSOLE_LOG"
    cat "$CONSOLE_LOG" >&2
    exit 1
  fi
  if grep -q "listening on $VIDEO_PORT" "$CONSOLE_LOG" 2>/dev/null; then
    break
  fi
  sleep 1
done

# --- 4. Launch the app.
LAUNCH_ARGS=(-console.host 127.0.0.1 -autoConnect YES -streamDiagnostics YES)
if [[ -n "$EXTRA_ARGS" ]]; then
  # shellcheck disable=SC2206
  LAUNCH_ARGS+=($EXTRA_ARGS)
fi
log "launching app with: ${LAUNCH_ARGS[*]}"
LAUNCH_START_EPOCH=$(date +%s)
LAUNCH_START_LOGSHOW="$(date -u '+%Y-%m-%d %H:%M:%S+0000')"
LAUNCH_OUT="$(xcrun simctl launch "$UDID" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" 2>&1)"
echo "$LAUNCH_OUT"
APP_PID="$(echo "$LAUNCH_OUT" | grep -oE '[0-9]+$' | tail -1)"
if [[ -z "$APP_PID" ]]; then
  log "could not parse launched pid from: $LAUNCH_OUT"
  kill "$FAKE_PID" 2>/dev/null
  exit 1
fi
log "app launched, pid=$APP_PID"

# --- 5. Sample RSS every 60s, watch for the process dying or a new crash report,
#        for the full requested duration.
CRASHED=0
CRASH_FILE=""
START_EPOCH=$(date +%s)
END_EPOCH=$((START_EPOCH + DURATION))
RSS_START=""
RSS_END=""
echo "epoch,rss_kb" >> "$RSS_LOG"
while [[ $(date +%s) -lt $END_EPOCH ]]; do
  RSS="$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ')"
  NOW=$(date +%s)
  if [[ -z "$RSS" ]]; then
    log "process $APP_PID is gone at t=$((NOW - START_EPOCH))s"
    CRASHED=1
    break
  fi
  echo "${NOW},${RSS}" >> "$RSS_LOG"
  [[ -z "$RSS_START" ]] && RSS_START="$RSS"
  RSS_END="$RSS"
  NEW_IPS="$(find "$REPORTS_DIR" -maxdepth 1 -iname "Kagami-*.ips" 2>/dev/null | sort | comm -13 "$BEFORE_IPS" -)"
  if [[ -n "$NEW_IPS" ]]; then
    log "new crash report detected: $NEW_IPS"
    CRASHED=1
    CRASH_FILE="$NEW_IPS"
    break
  fi
  sleep 60
done

ELAPSED=$(( $(date +%s) - START_EPOCH ))
log "soak window done after ${ELAPSED}s (crashed=$CRASHED)"

# --- 6. Pull the diagnostics log covering the whole run, whether or not it crashed.
# Plain `log show` text, not --style ndjson: each line ends in
# "[com.kagami.app:diagnostics] {json}" (confirmed against a real capture from this
# same predicate), and the python step below just pulls the JSON tail off each line
# rather than depending on ndjson's own wrapping.
log "collecting diagnostics log"
/usr/bin/log show --predicate 'subsystem == "com.kagami.app" AND category == "diagnostics"' \
    --start "$LAUNCH_START_LOGSHOW" > "$DIAG_LOG" 2>/dev/null

# --- 7. Tear down: terminate the app, kill the fake console. Never leave either
#        running past this script, and never shut down the simulator here if we did
#        not boot it ourselves — some other soak or session may still be using it (the
#        caller decides whether to shut it down once ALL of its soaks are done).
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
kill "$FAKE_PID" 2>/dev/null
wait "$FAKE_PID" 2>/dev/null
pkill -f "fake-console.py" 2>/dev/null || true

# --- 8. Reduce the diagnostics log into the summary the task asked for.
python3 - "$DIAG_LOG" "$RSS_LOG" "$OUT_JSON" "$LABEL" "$CRASHED" "$CRASH_FILE" "$ELAPSED" <<'PY'
import json
import sys
import statistics

diag_path, rss_path, out_path, label, crashed, crash_file, elapsed = sys.argv[1:8]
crashed = bool(int(crashed))

MARKER = "[com.kagami.app:diagnostics] "

lines = []
try:
    with open(diag_path, errors="replace") as f:
        for raw in f:
            idx = raw.find(MARKER)
            if idx == -1:
                continue
            tail = raw[idx + len(MARKER):].strip()
            try:
                payload = json.loads(tail)
            except ValueError:
                continue
            if isinstance(payload, dict) and "framesDecoded" in payload:
                lines.append(payload)
except FileNotFoundError:
    pass

def last(key, default=None):
    for entry in reversed(lines):
        if key in entry:
            return entry[key]
    return default

def series(key):
    return [e[key] for e in lines if key in e]

displayed_fps_series = series("framesDisplayedPerSecond")
# A stall in fake-console.py's own traffic (--stall-ms 800 every --stall-every 5s)
# legitimately drives displayed fps to 0 for under a second; only sustained zeros
# outside that pattern are this pipeline's problem. Approximate "outside stalls" by
# dropping the bottom ~20% of ticks (roughly one 800ms stall per 5s window at 1Hz
# sampling) before computing percentiles, so a real freeze (many consecutive zeros)
# still shows up clearly while the expected periodic dip does not dominate p5/mean.
non_zero_fps = [v for v in displayed_fps_series if v and v > 0]

def percentile(data, p):
    if not data:
        return None
    data = sorted(data)
    k = (len(data) - 1) * p
    f = int(k)
    c = min(f + 1, len(data) - 1)
    if f == c:
        return data[f]
    return data[f] + (data[c] - data[f]) * (k - f)

# Longest run of consecutive zero-fps ticks, to distinguish a permanent freeze from
# the fake console's own periodic 800ms stalls (diagnostics ticks at ~1Hz here).
max_zero_run = 0
cur_zero_run = 0
for v in displayed_fps_series:
    if v == 0:
        cur_zero_run += 1
        max_zero_run = max(max_zero_run, cur_zero_run)
    else:
        cur_zero_run = 0

rss_values = []
try:
    with open(rss_path) as f:
        next(f, None)
        for row in f:
            row = row.strip()
            if not row or "," not in row:
                continue
            _, rss_kb = row.split(",", 1)
            try:
                rss_values.append(int(rss_kb))
            except ValueError:
                pass
except FileNotFoundError:
    pass

summary = {
    "label": label,
    "elapsedSeconds": int(elapsed),
    "crashed": crashed,
    "crashFile": crash_file or None,
    "diagnosticsLineCount": len(lines),
    "framesDecoded": last("framesDecoded"),
    "framesDisplayed": last("framesDisplayed"),
    "reconnects": last("reconnects"),
    "keyframeWaitsEntered": last("keyframeWaitsEntered"),
    "decodeErrors": last("decodeErrors"),
    "decoderResets": last("decoderResets"),
    "displayedFpsMin": min(displayed_fps_series) if displayed_fps_series else None,
    "displayedFpsP5": percentile(displayed_fps_series, 0.05),
    "displayedFpsMean": statistics.mean(displayed_fps_series) if displayed_fps_series else None,
    "displayedFpsP5OutsideStalls": percentile(non_zero_fps, 0.05),
    "displayedFpsMeanOutsideStalls": statistics.mean(non_zero_fps) if non_zero_fps else None,
    "maxConsecutiveZeroFpsTicks": max_zero_run,
    "audioFillMillisP95": percentile(series("audioFillMillis"), 0.95),
    "avSkewMicrosMax": max((abs(v) for v in series("avSkewMicros")), default=None),
    "rssStartKb": rss_values[0] if rss_values else None,
    "rssEndKb": rss_values[-1] if rss_values else None,
    "rssGrowthKb": (rss_values[-1] - rss_values[0]) if len(rss_values) >= 2 else None,
    "diagnosticsLog": diag_path,
    "rssLog": rss_path,
}

with open(out_path, "w") as f:
    json.dump(summary, f, indent=2)

print(json.dumps(summary, indent=2))
PY

log "wrote $OUT_JSON"
