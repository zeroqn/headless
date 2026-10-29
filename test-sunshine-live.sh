#!/usr/bin/env bash
#
# Live end-to-end test for the Sunshine source build.
#
#   ./test-sunshine-live.sh
#
# Builds .#sunshineReleaseBuild (or uses SUN_BIN), starts it against a headless
# wlroots compositor, and runs the moonlight-common-c test client through three
# scenarios:
#
#   1. one client at 1280x720@60 with microphone audio, captured from the
#      "sunshine-mic" PipeWire source and analysed (tone + silence check)
#   2. two clients with distinct paired certificates at the same time, which
#      must both stream on the serialised encode path without stopping the host
#   3. a reconnect with the same certificate, which must replace the stale
#      session instead of leaving a second encoder running
#
# Requires the test assets (paired client certificates, client state, apps file
# and the built test client) from the mic-diag harness:
#
#   TEST_ASSETS=/path/to/mic-diag ./test-sunshine-live.sh
#
# Logs land in .scratch/sunshine-live/<timestamp>/.
set -uo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
assets=${TEST_ASSETS:-$repo_dir/.scratch/mic-diag}
out=${OUT:-$repo_dir/.scratch/sunshine-live/$(date +%Y%m%d-%H%M%S)}
client_seconds=${CLIENT_SECONDS:-20}

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
note() { printf '== %s\n' "$*"; }

for asset in mic_client_res client.pem client.key client2.pem client2.key sunshine_state2.json apps.json; do
  if [ ! -e "$assets/$asset" ]; then
    echo "missing test asset: $assets/$asset (set TEST_ASSETS)" >&2
    exit 2
  fi
done

mkdir -p "$out"

if [ -z "${SUN_BIN:-}" ]; then
  note "building .#sunshineReleaseBuild"
  if ! nix build "$repo_dir#sunshineReleaseBuild" --out-link "$out/sunshine-build" > "$out/build.log" 2>&1; then
    echo "build failed, see $out/build.log" >&2
    tail -20 "$out/build.log" >&2
    exit 2
  fi
  SUN_BIN=$out/sunshine-build/bin/sunshine
fi
note "sunshine: $SUN_BIN ($("$SUN_BIN" --version 2>&1 | head -1))"

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
unset WAYLAND_DISPLAY

pkill -f "sunshine .*sunshine-test.conf" 2>/dev/null
pkill -f mic_client 2>/dev/null
pkill -f 'foot.*date' 2>/dev/null
sleep 1

compositor_pid=
if ! ls "$XDG_RUNTIME_DIR"/wayland-[0-9] >/dev/null 2>&1; then
  note "starting headless sway (vulkan renderer)"
  WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=vulkan WLR_LIBINPUT_NO_DEVICES=1 \
    nix shell nixpkgs#sway -c sway --config "$assets/sway.conf" > "$out/sway.log" 2>&1 &
  compositor_pid=$!
  for _ in $(seq 1 80); do ls "$XDG_RUNTIME_DIR"/wayland-[0-9] >/dev/null 2>&1 && break; sleep 0.25; done
fi
export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR"/wayland-[0-9] 2>/dev/null | grep -v lock | head -1 | xargs -r basename)
if [ -z "$WAYLAND_DISPLAY" ]; then
  echo "no Wayland socket in $XDG_RUNTIME_DIR" >&2
  exit 2
fi
note "WAYLAND_DISPLAY=$WAYLAND_DISPLAY, logs in $out"

# animate the output so the capture path always has new frames
nix shell nixpkgs#foot -c foot -- bash -c 'while :; do date +%N; sleep 0.02; done' > "$out/foot.log" 2>&1 &
motion_pid=$!
sleep 2

cp "$assets/sunshine-test.conf" "$out/sunshine.conf"
"$SUN_BIN" "$out/sunshine.conf" system_tray=false file_state="$assets/sunshine_state2.json" \
      min_log_level=info log_path="$out/sunshine.log" apps_file="$assets/apps.json" \
      encoder=vulkan capture=wlr address_family=ipv4 port=47989 > "$out/sunshine.stdout" 2>&1 &
sunpid=$!
cleanup() {
  kill "$sunpid" "$motion_pid" "$compositor_pid" 2>/dev/null
  wait "$sunpid" "$motion_pid" "$compositor_pid" 2>/dev/null
  pkill -f "sunshine .*sunshine-test.conf" 2>/dev/null
}
trap cleanup EXIT

ready=
for _ in $(seq 1 160); do
  if (exec 3<>/dev/tcp/127.0.0.1/47989) 2>/dev/null; then ready=1; break; fi
  sleep 0.25
done
if [ -z "$ready" ]; then
  echo "sunshine did not start listening on 47989, see $out/sunshine.stdout" >&2
  exit 2
fi

cd "$assets"
wait_for_stream() {  # $1 = client log
  for _ in $(seq 1 160); do grep -q 'first video packet' "$1" 2>/dev/null && return 0; sleep 0.25; done
  return 1
}
# "keyframes=1" must not be read as "frames=1"
frames_of() { grep -oE '\bframes=[0-9]+' "$1" 2>/dev/null | tail -1 | cut -d= -f2; }
wait_for_log() {  # $1 = pattern, waits up to 10s for it in the sunshine log
  for _ in $(seq 1 40); do grep -qE "$1" "$out/sunshine.log" 2>/dev/null && return 0; sleep 0.25; done
  return 1
}

# ---------------------------------------------------------------- 1: one client + microphone
note "scenario 1: one client + microphone"
./mic_client_res 127.0.0.1 "$((client_seconds + 8))" client.pem client.key 1280x720 60 > "$out/client-1.log" 2>&1 &
c1=$!
if wait_for_stream "$out/client-1.log"; then pass "client received video"; else fail "client never received video"; fi
sleep 2
nodes_streaming=$(pw-cli ls Node 2>/dev/null | grep -c 'node.name = "sunshine-mic')
pw-record --target sunshine-mic --rate 48000 --channels 1 "$out/mic.wav" > "$out/pw-record.log" 2>&1 &
rec=$!
sleep 5
kill "$rec" 2>/dev/null
wait "$rec" 2>/dev/null
wait "$c1" 2>/dev/null
frames=$(frames_of "$out/client-1.log")
if [ "${frames:-0}" -gt 100 ]; then pass "client decoded $frames frames"; else fail "client decoded ${frames:-0} frames"; fi
sent=$(grep -oE 'mic frames sent=[0-9]+' "$out/client-1.log" | tail -1 | cut -d= -f2)
if [ "${sent:-0}" -gt 0 ]; then pass "client sent $sent microphone packets"; else fail "client sent no microphone packets"; fi
wait_for_log 'Microphone diagnostics \(sessions ended\)'
accepted=$(grep -oE 'accepted=[0-9]+' "$out/sunshine.log" | tail -1 | cut -d= -f2)
if [ "${accepted:-0}" -gt 0 ]; then pass "host mixed $accepted microphone packets"; else fail "host mixed no microphone packets"; fi
if grep -q 'opus_decode_failed=0' "$out/sunshine.log"; then pass "no opus decode failures"; else fail "microphone packets failed to decode"; fi
if [ "${nodes_streaming:-0}" -ge 1 ]; then pass "sunshine-mic node present while streaming ($nodes_streaming)"; else fail "no sunshine-mic node while streaming"; fi

cat > "$out/analyze.py" <<'PY'
import array, math, sys, wave
w = wave.open(sys.argv[1])
frames, rate = w.getnframes(), w.getframerate()
samples = array.array("h")
samples.frombytes(w.readframes(frames))
if not len(samples):
    print("peak=0 rms=0 freq=0 silent=1 windows=1")
    raise SystemExit(0)
peak = max(abs(s) for s in samples)
rms = math.sqrt(sum(s * s for s in samples) / len(samples))
crossings = sum(1 for i in range(1, len(samples)) if (samples[i - 1] < 0) != (samples[i] < 0))
window = max(1, int(rate * 0.02))
windows = len(samples) // window
silent = sum(1 for i in range(windows) if max(abs(s) for s in samples[i * window:(i + 1) * window]) < 100)
print(f"peak={peak} rms={rms:.0f} freq={crossings / 2 / (len(samples) / rate):.1f} silent={silent} windows={windows}")
PY
if command -v python3 >/dev/null 2>&1; then
  mic_stats=$(python3 "$out/analyze.py" "$out/mic.wav" 2>/dev/null)
else
  mic_stats=$(nix shell nixpkgs#python3 -c python3 "$out/analyze.py" "$out/mic.wav" 2>/dev/null)
fi
peak=$(echo "$mic_stats" | sed -n 's/.*peak=\([0-9]*\).*/\1/p')
freq=$(echo "$mic_stats" | sed -n 's/.*freq=\([0-9.]*\).*/\1/p')
silent=$(echo "$mic_stats" | sed -n 's/.*silent=\([0-9]*\).*/\1/p')
windows=$(echo "$mic_stats" | sed -n 's/.*windows=\([0-9]*\).*/\1/p')
if [ "${peak:-0}" -gt 1000 ]; then
  pass "captured microphone audio: peak=$peak rms=$(echo "$mic_stats" | sed -n 's/.*rms=\([0-9]*\).*/\1/p') ${freq}Hz"
else
  fail "captured microphone audio is silent ($mic_stats)"
fi
if [ "${silent:-1}" -le 1 ]; then
  pass "no dropouts in the captured audio ($silent of $windows silent 20 ms windows)"
else
  fail "$silent of $windows silent 20 ms windows in the captured audio"
fi
if grep -q 'Virtual microphone released' "$out/sunshine.log"; then pass "virtual microphone released on session end"; else fail "virtual microphone not released"; fi

# ---------------------------------------------------------------- 2: two clients
note "scenario 2: two clients with distinct certificates"
./mic_client_res 127.0.0.1 "$((client_seconds + 10))" client.pem client.key 1280x720 60 > "$out/client-2a.log" 2>&1 &
c2a=$!
wait_for_stream "$out/client-2a.log"
sleep 3
./mic_client_res 127.0.0.1 "$client_seconds" client2.pem client2.key 1280x720 60 > "$out/client-2b.log" 2>&1 &
c2b=$!
if wait_for_stream "$out/client-2b.log"; then pass "second client received video"; else fail "second client never received video"; fi
sleep 6
if kill -0 "$sunpid" 2>/dev/null; then pass "host process alive with two sessions"; else fail "host process died with two sessions"; fi
wait "$c2b" 2>/dev/null
r2b=$?
wait "$c2a" 2>/dev/null
r2a=$?
framesA=$(frames_of "$out/client-2a.log")
framesB=$(frames_of "$out/client-2b.log")
if [ "${framesA:-0}" -gt 100 ] && [ "${framesB:-0}" -gt 100 ]; then
  pass "both clients streamed concurrently ($framesA + $framesB frames)"
else
  fail "concurrent sessions delivered too few frames ($framesA + $framesB)"
fi
if [ "$(grep -c 'Capture/encode path for this session: serialized' "$out/sunshine.log")" -ge 3 ]; then
  pass "sessions encoded on the serialised capture thread"
else
  fail "a session did not use the serialised encode path"
fi

# ---------------------------------------------------------------- 3: reconnect
note "scenario 3: reconnect with the same certificate"
./mic_client_res 127.0.0.1 "$((client_seconds + 4))" client.pem client.key 1280x720 60 > "$out/client-3a.log" 2>&1 &
c3a=$!
wait_for_stream "$out/client-3a.log"
sleep 3
./mic_client_res 127.0.0.1 "$client_seconds" client.pem client.key 1280x720 60 > "$out/client-3b.log" 2>&1 &
c3b=$!
if wait_for_stream "$out/client-3b.log"; then pass "reconnect received video"; else fail "reconnect never received video"; fi
sleep 4
wait "$c3b" 2>/dev/null
wait "$c3a" 2>/dev/null
if wait_for_log 'Terminated 1 stale session\(s\)'; then
  pass "reconnect replaced the stale session"
else
  fail "stale session was not replaced on reconnect"
fi

# ---------------------------------------------------------------- host health
note "host health"
if kill -0 "$sunpid" 2>/dev/null; then pass "sunshine still running at the end"; else fail "sunshine exited"; fi
alive=$(grep -icE 'Segmentation fault|terminate called|Assertion .* failed|SIGSEGV|SIGFPE' "$out/sunshine.log")
if [ "$alive" -eq 0 ]; then pass "no crash markers in the sunshine log"; else fail "$alive crash markers in the sunshine log"; fi
left=$(pgrep -fc sunshine-mic 2>/dev/null)
if [ "${left:-0}" -eq 0 ]; then pass "no sunshine-mic nodes left behind"; else fail "$left sunshine-mic nodes left behind"; fi

printf '\n%s\n' "----------------------------------------"
if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS (logs: $out)"
else
  echo "RESULT: FAIL ($failures check(s) failed, logs: $out)"
fi
exit $(( failures > 0 ))
