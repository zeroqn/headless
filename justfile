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
