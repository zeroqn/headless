#!/usr/bin/env bash
# Run the virgl render-server / venus probe on the L1 host.
#
# Locates virglrenderer in the Nix store, sets the env virglrenderer needs to
# find its render server, optionally prints a host-Vulkan precheck, then
# compiles the probe and runs the requested mode(s).
#
# Usage:
#   bash run-probe.sh                 # run venus, venus-rs, loftd, loftd-rs
#   bash run-probe.sh venus-rs        # run a single mode
#   bash run-probe.sh all             # same as no arg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_vgl() {
    local d
    # Prefer an explicit env override (set by the flake devShell) so we don't
    # depend on globbing the store in a particular order.
    if [[ -n "${VIRGLRENDERER:-}" && -f "$VIRGLRENDERER/lib/libvirglrenderer.so" ]]; then
        printf '%s\n' "$VIRGLRENDERER"
        return 0
    fi
    for d in /nix/store/*virglrenderer-1.3.0; do
        if [[ -f "$d/lib/libvirglrenderer.so" &&
              -f "$d/include/virgl/virglrenderer.h" &&
              -x "$d/libexec/virgl_render_server" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

VGL="$(find_vgl || true)"
if [[ -z "$VGL" ]]; then
    echo "virglrenderer-1.3.0 not found in /nix/store" >&2
    echo "Add it to the dev shell, or pass the store path via PKG_CONFIG_PATH." >&2
    exit 1
fi
echo "using virglrenderer at: $VGL"

# RENDER_SERVER_EXEC_PATH is the env var virglrenderer reads (via execv) to
# locate its render-server binary; VIRGL_RENDER_SERVER_PATH is not used. VK_LIBDIR,
# if set (e.g. by the flake devShell), makes libvulkan.so.1 findable at runtime.
export LD_LIBRARY_PATH="${VK_LIBDIR:+$VK_LIBDIR:}$VGL/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export RENDER_SERVER_EXEC_PATH="$VGL/libexec/virgl_render_server"
export PATH="$VGL/libexec:$VGL/bin:$PATH"

echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo "RENDER_SERVER_EXEC_PATH=$RENDER_SERVER_EXEC_PATH"
echo "VK_DRIVER_FILES=${VK_DRIVER_FILES:-<unset>}  VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-<unset>}"
echo

# Optional friendly host-Vulkan precheck.  It is not authoritative: the probe's
# own venus capset / context results are the real signal (the render server
# inherits this same environment).
if command -v vulkaninfo >/dev/null 2>&1; then
    echo "--- vulkaninfo --summary ---"
    vulkaninfo --summary 2>&1 | head -40 || true
    echo
else
    echo "vulkaninfo not found; skipping host-Vulkan precheck (ICD env above is all we set)."
fi

# Bake the store lib dir into the binary as an RPATH so the probe is
# self-contained under NixOS (no global linker search path, and LD_LIBRARY_PATH
# is only set inside this script -- running ./virgl-probe directly would
# otherwise fail to find libvirglrenderer.so.1).
gcc -O2 -Wall -Wno-deprecated-declarations \
    "$SCRIPT_DIR/probe.c" \
    -I"$VGL/include" -L"$VGL/lib" -lvirglrenderer -ldl -lpthread \
    -Wl,-rpath,"$VGL/lib" \
    -o "$SCRIPT_DIR/virgl-probe"

modes="${1:-}"
if [[ -z "$modes" || "$modes" == "all" ]]; then
    modes="venus venus-rs loftd loftd-rs"
fi

rc=0
for m in $modes; do
    echo "=============== mode: $m ==============="
    timeout 60 "$SCRIPT_DIR/virgl-probe" "$m" || rc=1
    echo
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x virgl_render_server >/dev/null 2>&1; then
            echo "(virgl_render_server process is running)"
        else
            echo "(no virgl_render_server process after this mode)"
        fi
    fi
done

exit $rc
