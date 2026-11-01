#!/usr/bin/env bash
#
# diagnose-serverinfo.sh — "Moonlight says this host is offline, but Sunshine is running."
#
#   ./diagnose-serverinfo.sh            # probe and report
#   ./diagnose-serverinfo.sh --stack    # also dump thread stacks (needs root/gdb)
#
# Reproduces what Moonlight actually does to decide a host is online: one HTTPS
# GET /serverinfo on 47984, carrying a client certificate. Two details matter and both
# have produced false readings before:
#
#   * 47984 requires a client certificate (verify_fail_if_no_peer_cert), so a cert-less
#     curl gets 000 even against a perfectly healthy Sunshine. This script always sends
#     one, generated into the report directory.
#   * A healthy front end answers an *unpaired* certificate with the pairing challenge:
#     HTTP 200 carrying status_code="401". So 200 or 401 both mean "the front end is
#     alive and processed the request"; 000 means it did not answer at all.
#
# Exit codes:  0 front end healthy, 1 front end not answering, 2 not running/not bound,
#              3 healthy but something else is wrong (client/network/discovery).
set -uo pipefail

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

stack=0
for arg in "$@"; do
  case "$arg" in
    --stack) stack=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 64 ;;
  esac
done

timeout_s=5
https_port=${SUNSHINE_HTTPS_PORT:-47984}
http_port=${SUNSHINE_HTTP_PORT:-47989}
probe_id=${SUNSHINE_PROBE_ID:-0123456789abcdef0123456789abcdef}
root=${DIAG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.scratch/serverinfo-diag}
outdir=$root/$(date +%Y%m%d-%H%M%S)
certdir=$outdir/certs
mkdir -p "$certdir" || { outdir=$(mktemp -d); certdir=$outdir/certs; mkdir -p "$certdir"; }
chmod 700 "$outdir"

exec > >(tee "$outdir/report.txt") 2>&1

say() { printf '%s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

command -v curl >/dev/null || { say "curl is required"; exit 2; }

# ---------------------------------------------------------------- process and unit
head_ "process"
sunpid=$(pgrep -f 'sunshine-wrapped|bin/sunshine' | head -1)
if [ -z "$sunpid" ]; then
  note "no sunshine process found -- this is a 'not running' failure, not a wedged front end"
else
  note "pid $sunpid: $(ps -o args= -p "$sunpid" | cut -c1-120)"
  note "owner: $(ps -o user= -p "$sunpid" | tr -d ' ') (this shell: $(id -un))"
  exe=$(readlink -f "/proc/$sunpid/exe" 2>/dev/null)
  note "binary: ${exe:-unknown}"
  [ -x "$exe" ] && note "version: $("$exe" --version 2>&1 | head -1)"
  note "uptime: $(ps -o etime= -p "$sunpid" | tr -d ' ')"
fi

head_ "service"
if command -v systemctl >/dev/null; then
  note "user unit active: $(systemctl --user is-active sunshine.service 2>/dev/null)"
  note "Restart policy:   $(systemctl --user show -p Restart --value sunshine.service 2>/dev/null)"
  note "SubState:         $(systemctl --user show -p SubState --value sunshine.service 2>/dev/null)"
  if systemctl --user cat sunshine-health.timer >/dev/null 2>&1; then
    note "health timer:     $(systemctl --user is-active sunshine-health.timer 2>/dev/null), next: $(systemctl --user list-timers --all --no-pager sunshine-health.timer 2>/dev/null | sed -n '2p' | sed 's/  */ /g')"
    note "health timer log: $(journalctl --user -u sunshine-health --no-pager -n 5 2>/dev/null | tail -3 | tr '\n' '|')"
  else
    note "health timer:     not installed"
  fi
  note "watchdog trips:   $(journalctl --user -u sunshine.service --no-pager 2>/dev/null | grep -c 'Hang detected') (Hang detected lines in the journal)"
fi

# ---------------------------------------------------------------- listeners
head_ "listeners"
if command -v ss >/dev/null; then
  listening=$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ":($https_port|$http_port)\$" | tr '\n' ' ')
  note "bound: ${listening:-<none>}"
  note "established on $https_port: $(ss -tn state established "( sport = :$https_port )" 2>/dev/null | tail -n +2 | awk '{print $1, $2, $3}' | tr '\n' ' ')"
else
  note "ss not available; skipping listener check"
  listening=""
fi

# ---------------------------------------------------------------- probes
gen_cert() {
  local args=(req -x509 -newkey rsa:2048 -nodes -subj /CN=sunshine-diag -days 1
              -keyout "$certdir/client.key" -out "$certdir/client.pem")
  if command -v openssl >/dev/null; then
    openssl "${args[@]}" >/dev/null 2>&1
  elif command -v nix >/dev/null; then
    nix shell nixpkgs#openssl -c openssl "${args[@]}" >/dev/null 2>&1
  fi
  [ -s "$certdir/client.pem" ]
}

probe_plain() {
  local code
  code=$(curl -sS --max-time "$timeout_s" -o "$outdir/plain.body" -w '%{http_code}' \
    "http://127.0.0.1:$http_port/serverinfo?uniqueid=$probe_id" 2>"$outdir/plain.err")
  printf '%s' "${code:-000}"
}

probe_tls() {
  local args=(-sk --max-time "$timeout_s" -o "$outdir/tls.body" -w '%{http_code}') code
  if [ -s "$certdir/client.pem" ]; then
    args+=(--cert "$certdir/client.pem" --key "$certdir/client.key")
  fi
  code=$(curl "${args[@]}" "https://127.0.0.1:$https_port/serverinfo?uniqueid=$probe_id" 2>"$outdir/tls.err")
  printf '%s' "${code:-000}"
}

head_ "probe: Moonlight's own request (TLS $https_port + client certificate)"
if gen_cert; then
  note "throwaway client certificate: $certdir/client.pem ($(openssl x509 -in "$certdir/client.pem" -noout -subject 2>/dev/null || echo 'subject unavailable'))"
else
  note "WARNING: no openssl and no nix, sending the probe without a client certificate;"
  note "         a 000 below is then inconclusive (47984 rejects certificate-less handshakes)"
fi
tls_code=$(probe_tls)
tls_status=$(grep -oE 'status_code="[0-9]+"' "$outdir/tls.body" 2>/dev/null | head -1 | grep -oE '[0-9]+')
note "HTTP status: $tls_code${tls_status:+   body status_code: $tls_status}"
[ -s "$outdir/tls.err" ] && note "curl: $(tr '\n' ' ' < "$outdir/tls.err" | cut -c1-200)"

head_ "probe: plain HTTP $http_port"
plain_code=$(probe_plain)
note "HTTP status: $plain_code"
[ -s "$outdir/plain.err" ] && note "curl: $(tr '\n' ' ' < "$outdir/plain.err" | cut -c1-200)"

# ---------------------------------------------------------------- threads
head_ "threads"
if [ -n "$sunpid" ]; then
  ps -L -o tid,stat,wchan:30,comm -p "$sunpid" 2>/dev/null | sed 's/^/   /' | head -40
  stuck=$(ps -L -o stat= -p "$sunpid" 2>/dev/null | grep -cE '^[DR]')
  [ "${stuck:-0}" -gt 0 ] && note "$stuck thread(s) in D/R state (D = uninterruptible, a blocked kernel call)"
  nvhttp_wchan=$(ps -L -o wchan=,comm= -p "$sunpid" 2>/dev/null | awk '$2=="nvhttp::47984"{print $1}')
  note "nvhttp::$https_port wchan: ${nvhttp_wchan:-<thread not found>}"
fi

# ---------------------------------------------------------------- optional stacks
if [ "$stack" -eq 1 ] && [ -n "$sunpid" ]; then
  head_ "thread stacks"
  gdb_cmd=(gdb -p "$sunpid" -batch -ex 'thread apply all bt')
  if command -v gdb >/dev/null; then
    if sudo -n true 2>/dev/null; then
      sudo "${gdb_cmd[@]}" > "$outdir/threads.bt" 2>&1
    else
      note "skipping: needs root for ptrace and no passwordless sudo available"
      note "run manually: sudo gdb -p $sunpid -batch -ex 'thread apply all bt' > threads.bt"
    fi
  elif command -v nix >/dev/null; then
    if sudo -n true 2>/dev/null; then
      sudo nix shell nixpkgs#gdb -c gdb -p "$sunpid" -batch -ex 'thread apply all bt' > "$outdir/threads.bt" 2>&1
    else
      note "skipping: needs root for ptrace and no passwordless sudo available"
      note "run manually: sudo nix shell nixpkgs#gdb -c gdb -p $sunpid -batch -ex 'thread apply all bt'"
    fi
  fi
  if [ -s "$outdir/threads.bt" ]; then
    note "stacks: $outdir/threads.bt"
    awk '/nvhttp::47984/{show=1} show' "$outdir/threads.bt" | head -40 | sed 's/^/   /'
  fi
fi

# ---------------------------------------------------------------- verdict
head_ "verdict"
if [ -z "$sunpid" ]; then
  say "NOT RUNNING -- start the service; if it keeps exiting see: journalctl --user -u sunshine -n 50"
  say "report: $outdir/report.txt"
  exit 2
fi

if [ "$tls_code" = "000" ] && [ "$plain_code" = "000" ]; then
  say "BOTH FRONT ENDS SILENT with the process alive."
  say "The kernel has the listeners, the process is up, and nothing answers: a wedged front end"
  say "(re-run with --stack to see where the blocked thread sits)."
  say "report: $outdir/report.txt"
  exit 1
fi

if [ "$tls_code" = "000" ]; then
  say "TLS FRONT END ($https_port) DID NOT ANSWER, plain HTTP ($http_port) answered $plain_code."
  say "This is the reported failure mode: Moonlight polls only $https_port, so it shows the host"
  say "offline even though Sunshine is running. Re-run with --stack to name the blocked thread."
  say "report: $outdir/report.txt"
  exit 1
fi

if [ "$plain_code" != "200" ]; then
  say "PLAIN FRONT END ($http_port) answered $plain_code while TLS answered $tls_code."
  say "Discovery/pairing requests on $http_port are failing; check the service log."
  say "report: $outdir/report.txt"
  exit 1
fi

say "FRONT END HEALTHY -- $https_port answered $tls_code${tls_status:+ (status_code $tls_status)} and $http_port answered 200."
say "Sunshine is serving requests, so a client that still shows this host offline is failing"
say "elsewhere: the client's saved address or certificate, a firewall between the two, or"
say "discovery. Check on the client side, not here."
say "report: $outdir/report.txt"
exit 3
