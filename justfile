# Recipes for this flake. `just --list` shows everything.
set shell := ["bash", "-uc"]

default:
    @just --list

# Live end-to-end test of the Sunshine source build: one client with microphone
# capture from the sunshine-mic PipeWire source, two clients with distinct
# certificates streaming at the same time, and a reconnect with the same
# certificate. Builds .#sunshineReleaseBuild unless SUN_BIN is set.
#   just sunshine-live-test
#   SUN_BIN=./result-sunshine-prebuilt/bin/sunshine just sunshine-live-test
sunshine-live-test:
    ./test-sunshine-live.sh

# Diagnose a "Moonlight says the host is offline" report: probes both front ends the way
# Moonlight does, then captures listeners, connections, service state and thread states.
#   just diagnose-serverinfo
#   just diagnose-serverinfo --stack
diagnose-serverinfo *ARGS:
    ./diagnose-serverinfo.sh {{ARGS}}

# Sample a streaming session and report why it stutters: FEC blocks per frame (frames over
# the 4-block limit are sent without FEC), host-side capture+encode latency, and the UDP
# send rate. Streams 4K60 at 50 Mbps by default with the test client.
#   just diagnose-stream-quality
#   just diagnose-stream-quality --bitrate 150000 --extra-conf 'packetsize = 200'
diagnose-stream-quality *ARGS:
    ./diagnose-stream-quality.sh {{ARGS}}
