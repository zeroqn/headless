#!/usr/bin/env bash
#
# diagnose-stream-quality.sh — why does a stream stutter, and why does Sunshine skip FEC?
#
#   ./diagnose-stream-quality.sh                       # 30s session with the test client
#   ./diagnose-stream-quality.sh --duration 60
#   ./diagnose-stream-quality.sh --client none         # sample a session you start yourself
#   ./diagnose-stream-quality.sh --sun-bin /path/to/sunshine
#   ./diagnose-stream-quality.sh --extra-conf 'packetsize = 200'   # add config lines
#   ./diagnose-stream-quality.sh --resolution 3840x2160 --fps 60 --bitrate 50000   # defaults
#   ./diagnose-stream-quality.sh --conf configs/sunshine-vulkan-4k60.conf   # use a config file
#
# Samples one streaming session and reports, from the host side only:
#
#   * "Skipping FEC for abnormally large encoded frame (needed N FEC blocks)" -- how often,
#     and with which N. Sunshine packs a frame into at most 4 FEC blocks (2 header bits), so
#     a frame above 4 blocks is sent without FEC at all: a single lost packet then costs the
#     whole frame. The fix is a smaller maximum frame, not more FEC.
#   * the per-frame FEC block histogram (needs min_log_level=verbose), i.e. how close normal
#     frames run to that limit.
#   * "Frame processing latency (min/max/avg)" every 20s: capture+encode cost per frame. A
#     max far above the average is a host-side stall, not a network problem.
#   * UDP output rate during the stream (Sunshine sends the video), so an idle host, a slow
#     stream and a full-rate stream are told apart.
#
# Logs land in .scratch/stream-quality/<timestamp>/.
set -uo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
assets=${TEST_ASSETS:-$repo_dir/.scratch/mic-diag}
duration=${DURATION:-30}
resolution=${RESOLUTION:-3840x2160}
fps=${FPS:-60}
bitrate=${BITRATE:-50000}          # kbps requested from the host
client=${CLIENT:-}
conf_file=${CONF:-}
sun_bin=${SUN_BIN:-}
start_compositor=1
extra_conf=()

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) duration=$2; shift 2 ;;
    --conf) conf_file=$2; shift 2 ;;
    --resolution) resolution=$2; shift 2 ;;
    --fps) fps=$2; shift 2 ;;
    --bitrate) bitrate=$2; shift 2 ;;
    --client) client=$2; shift 2 ;;
    --sun-bin) sun_bin=$2; shift 2 ;;
    --no-compositor) start_compositor=0; shift ;;
    --extra-conf) extra_conf+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 64 ;;
  esac
done

out=$repo_dir/.scratch/stream-quality/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
exec > >(tee "$out/report.txt") 2>&1
note() { printf '%s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
unset PULSE_SERVER

if [ -z "$sun_bin" ]; then
  if command -v sunshine > /dev/null; then
    sun_bin=$(command -v sunshine)
  else
    note "no sunshine on PATH; pass --sun-bin or set SUN_BIN" >&2
    exit 2
  fi
fi
note "sunshine: $sun_bin"

udp_out() { awk '/^Udp:/{getline; print $2; exit}' /proc/net/snmp; }

compositor_pid=
if [ "$start_compositor" -eq 1 ] && ! ls "$XDG_RUNTIME_DIR"/wayland-[0-9] > /dev/null 2>&1; then
  if [ -f "$assets/sway.conf" ]; then
    # The captured output has to be the size we stream: wlgrab captures the compositor output, so
    # a small headless output would be upscaled to the client's viewport and the encoder would
    # never see 4K-sized frames.
    cp "$assets/sway.conf" "$out/sway.conf"
    printf 'output HEADLESS-1 resolution %s@%sHz\n' "$resolution" "$fps" >> "$out/sway.conf"
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=vulkan WLR_LIBINPUT_NO_DEVICES=1 \
      nix shell nixpkgs#sway -c sway --config "$out/sway.conf" > "$out/sway.log" 2>&1 &
    compositor_pid=$!
    for _ in $(seq 1 80); do ls "$XDG_RUNTIME_DIR"/wayland-[0-9] > /dev/null 2>&1 && break; sleep 0.25; done
  fi
fi
export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR"/wayland-[0-9] 2>/dev/null | grep -v lock | head -1 | xargs -r basename)
[ -n "$WAYLAND_DISPLAY" ] && note "wayland display: $WAYLAND_DISPLAY" || note "warning: no wayland display found"

# A config file under test is copied and given this run's machine-specific paths, so the file in
# the repository stays free of log/state paths.
conf=$out/sunshine.conf
if [ -n "$conf_file" ]; then
  cp "$conf_file" "$conf"
  sed -i '/^log_path\|^file_state\|^apps_file\|^port\|^address\|^system_tray/d' "$conf"
else
  if [ -f "$assets/sunshine-test.conf" ]; then
    cp "$assets/sunshine-test.conf" "$conf"
  else
    printf 'address = 0.0.0.0\nport = 47989\n' > "$conf"
  fi
fi
{
  printf 'log_path = %s\n' "$out/sunshine.log"
  printf 'port = 47989\n'
  printf 'system_tray = false\n'
  [ -f "$assets/sunshine_state2.json" ] && printf 'file_state = %s\n' "$assets/sunshine_state2.json"
  [ -f "$assets/apps.json" ] && printf 'apps_file = %s\n' "$assets/apps.json"
} >> "$conf"
for line in "${extra_conf[@]:-}"; do
  [ -n "$line" ] && printf '%s\n' "$line" >> "$conf"
done

pkill -f "sunshine .*$(basename "$conf")" 2>/dev/null
"$sun_bin" "$conf" system_tray=false min_log_level=verbose > "$out/sunshine.stdout" 2>&1 &
sun_pid=$!
cleanup() {
  pkill -f mic_client_res 2>/dev/null
  kill "$sun_pid" 2>/dev/null
  [ -n "$compositor_pid" ] && kill "$compositor_pid" 2>/dev/null
  sleep 1
}
trap cleanup EXIT

for _ in $(seq 1 160); do
  grep -q 'Adding avahi service' "$out/sunshine.stdout" 2>/dev/null && break
  kill -0 "$sun_pid" 2>/dev/null || break
  sleep 0.25
done
note "sunshine started (pid $sun_pid)"

client_pid=
if [ -z "$client" ] && [ -x "$assets/mic_client_res" ]; then
  client=$assets/mic_client_res
fi
if [ -n "$client" ] && [ "$client" != "none" ]; then
  if [ "$client" = "$assets/mic_client_res" ]; then
    ( cd "$assets" && ./mic_client_res 127.0.0.1 $((duration + 15)) client.pem client.key \
        "$resolution" "$fps" "$bitrate" > "$out/client.log" 2>&1 ) &
    client_pid=$!
  else
    sh -c "$client" > "$out/client.log" 2>&1 &
    client_pid=$!
  fi
  for _ in $(seq 1 240); do grep -q 'first video packet\|connectionStarted' "$out/client.log" 2>/dev/null && break; sleep 0.25; done
else
  note "no client started -- start Moonlight now; sampling for ${duration}s"
fi

head_ "sampling ${duration}s"
rate=""
start_udp=$(udp_out)
for _ in $(seq 1 "$duration"); do
  [ -n "$client_pid" ] && ! kill -0 "$client_pid" 2>/dev/null && break
  sleep 1
done
end_udp=$(udp_out)
streamed=$((end_udp - start_udp))
note "UDP datagrams sent by the host during the window: $streamed (~$((streamed / duration))/s)"
[ "$streamed" -gt 100 ] && note "a stream was running" || note "no stream traffic seen -- is a client connected?"

[ -n "$client_pid" ] && kill "$client_pid" 2>/dev/null
sleep 2

head_ "session"
note "requested: ${resolution}@${fps}, ${bitrate} kbps"
grep -hoE 'clientViewportWd=[0-9]+|clientViewportHt=[0-9]+|maxFPS=[0-9]+|initialBitrate=[0-9]+' \
  "$out/sunshine.log" 2>/dev/null | tail -4 | tr '\n' ' ' | sed 's/^/   client asked for: /'
echo
grep -hoE 'Creating encoder \[[a-z0-9_]+\]|\[VAAPI\] (Using [a-z]+ rate control[^|]*|Quality level set to [0-9]+[^|]*)|\[vulkan\] Encoder quality set to [0-9]+ \([a-z]+\)[^|]*|clientViewport[WH]t=[0-9]+|packetsize limit: [0-9]+ -> [0-9]+ bytes|Found [A-Za-z0-9]+ encoder: [^|]*' \
  "$out/sunshine.log" "$out/sunshine.stdout" 2>/dev/null | sort -u | sed 's/^/   /' | head -12

head_ "FEC"
fec_skips=$(grep -c 'Skipping FEC for abnormally large encoded frame' "$out/sunshine.log" 2>/dev/null)
too_large=$(grep -c 'Encoder produced a frame too large to send' "$out/sunshine.log" 2>/dev/null)
note "frames sent without FEC (over the 4-block limit): ${fec_skips:-0}"
note "frames too large to send at all:                  ${too_large:-0}"
if [ "${fec_skips:-0}" -gt 0 ]; then
  note "blocks that were needed:"
  grep -oE 'needed [0-9]+ FEC blocks' "$out/sunshine.log" | grep -oE '[0-9]+' | sort -n | uniq -c | sed 's/^/   /'
fi

blocks=$(grep -oE 'Generating [0-9]+ FEC blocks' "$out/sunshine.log" 2>/dev/null | grep -oE '[0-9]+')
if [ -n "$blocks" ]; then
  note "per-frame FEC blocks (verbose log):"
  printf '%s\n' "$blocks" | sort -n | uniq -c | sed 's/^/   /'
  note "frames logged: $(printf '%s\n' "$blocks" | wc -l); worst: $(printf '%s\n' "$blocks" | sort -n | tail -1) block(s) (limit 4)"
else
  note "no per-frame FEC lines -- was min_log_level=verbose accepted?"
fi

head_ "host-side frame pacing (capture + encode per frame, every 20s)"
grep -oE 'Frame processing latency \(min/max/avg\): [0-9.]+ms/[0-9.]+ms/[0-9.]+ms' "$out/sunshine.log" 2>/dev/null | sed 's/^/   /' | tail -8
worst=$(grep -oE 'Frame processing latency \(min/max/avg\): [0-9.]+ms/[0-9.]+ms' "$out/sunshine.log" 2>/dev/null |
        sed 's/.*: [0-9.]*ms\///; s/ms//' | sort -n | tail -1)
[ -n "$worst" ] && note "worst single-frame processing time: ${worst}ms"

head_ "client side"
if [ -s "$out/client.log" ]; then
  note "lib messages: $(grep -c '^\[lib\]' "$out/client.log" 2>/dev/null)"
  grep -E '^\[lib\].*(FEC|Unrecoverable|lost|drop|timeout)|connectionTerminated|stage .* FAILED' "$out/client.log" 2>/dev/null | tail -8 | sed 's/^/   /'
  grep -oE 'frames=[0-9]+' "$out/client.log" | tail -1 | sed 's/^/   /'
else
  note "no client log (host-only run)"
fi

head_ "verdict"
if [ "${fec_skips:-0}" -gt 0 ]; then
  note "Frames exceeding the 4-block FEC limit: those frames travel unprotected, so a single"
  note "lost packet costs the whole frame and the client shows a stutter exactly then."
  note "Cause is per-frame size, not the network. Options, cheapest first:"
  note "  - lower the stream bitrate, or raise the VBV/rate-control buffer so keyframes do not spike"
  note "    (vaapi: vaapi_strict_rc_buffer; vulkan: use a VBV-limited rate control, avoid CRF-like modes)"
  note "  - raise 'packetsize' in sunshine.conf (stream section, <= 1456 unless the path is jumbo-frame"
  note "    clean): a bigger block needs fewer blocks per frame"
  note "  - lower 'fec_percentage' only moves the limit slightly and weakens loss recovery"
elif [ -n "$worst" ] && [ "${worst%%.*}" -gt 20 ]; then
  note "Frame processing latency peaks at ${worst}ms while the average is low: the host stalls"
  note "(capture/encode), so the jitter is not on the wire. Check for other GPU users and the"
  note "capture path (wlgrab screencopy vs KMS) during the stall."
elif [ "$streamed" -le 100 ]; then
  note "No stream traffic was captured, so nothing can be concluded -- re-run with a client."
else
  note "No FEC skips and no host-side stalls in this window; packet loss on the path is the"
  note "next thing to look at (client-side counters, switch/Wi-Fi statistics)."
fi
note ""
note "logs: $out"
