# virgl-render-server-probe

Host-side diagnostic for the L1 machine (the one with the AMD GPU in native
context). It answers a single question:

> Does this host's virglrenderer support the **VENUS** renderer in
> **RENDER_SERVER** mode — the path a nested libkrun **L2** guest would use to
> run a **Vulkan** app?

It drives `virgl_renderer_init` + the venus capset query + a venus
`context_create_with_flags` directly — the same sequence libkrun/rutabaga uses
on the host, but with no loftd sandbox involved. That isolates the host-side
GPU/renderer capability from loftd's own seccomp/Landlock integration, which is
where the earlier `RENDER_SERVER` work died (SIGSYS on `socketpair`).

## Why venus + RENDER_SERVER on the L1?

Linux GPU **native context does not nest**, so an L2 guest's virtio-gpu must be
virgl mode. Guest **Vulkan** for that path comes from the **venus** renderer,
which is a separate axis from native-context DRM/EGL:

- venus renders through a **host Vulkan device** (radv on an AMD GPU).
- `VIRGL_RENDERER_RENDER_SERVER` (bit 9) is the only flag **respected by venus**
  (the GL virgl renderer ignores it). It moves venus rendering into a
  standalone `virgl_render_server` process.
- With `get_server_fd` returning `-1` (what this probe does, mirroring
  libkrun/rutabaga which passes `render_server_fd=None`), virglrenderer
  self-spawns the render server via `socketpair → fork → execv`. On a bare L1
  host that is the normal, unsandboxed path.

So the decisive host-side gates, in order, are:

1. `virgl_renderer_init(VENUS | … | RENDER_SERVER)` returns 0.
2. The venus capset (id 4) is present (`max_size > 0`). Note this is only the
   fixed capset struct size reported by the proxy process — it is NOT proof of
   a device; the probe's device list is the real hardware check.
3. A venus context can be created.

This probe prints all three for several flag sets.

## Files

- `probe.c` — the probe (links the installed virglrenderer; v4 callback header).
- `run-probe.sh` — locates virglrenderer under `/nix/store`, sets
  `LD_LIBRARY_PATH` / `RENDER_SERVER_EXEC_PATH` / `PATH`, optionally prints a
  `vulkaninfo` precheck, compiles the probe, and runs the requested modes.
- `flake.nix` — a Nix flake: a `virgl-probe` package (`nix build`/`nix run`),
  a devShell (`nix develop`) with gcc + virglrenderer + the Vulkan loader/tools,
  and an `apps.default` entry point.
- `README.md` — this file.

## Build & run (on the L1 host)

```bash
cd tools/virgl-render-server-probe
bash run-probe.sh            # runs all four modes (venus, venus-rs, loftd, loftd-rs)
bash run-probe.sh venus-rs   # single mode
```

`run-probe.sh` finds a `virglrenderer-1.3.0` store path that has the header, the
shared library, and `libexec/virgl_render_server`, then compiles and runs
`probe.c` against it. If your AMD Vega/Radeon Vulkan driver (radv) is present as
an ICD, it is enough to leave the environment as-is; optionally export
`VK_DRIVER_FILES` / `VK_ICD_FILENAMES` to pick the radv ICD explicitly.

NixOS note: the compile bakes the resolved store `lib` dir into the binary as an
RPATH (`-Wl,-rpath,$VGL/lib`), so the resulting `virgl-probe` is self-contained
and can be invoked directly `./virgl-probe <mode>` without setting
`LD_LIBRARY_PATH`. This matters because NixOS has no global linker search path —
running the binary directly would otherwise fail with
`libvirglrenderer.so.1: cannot open shared object file`. The trade-off is that
the binary is tied to the store path it was built against; rebuild via
`run-probe.sh` if that path changes or is garbage-collected.

To run a raw flag mask instead of a named mode (either form works):

```bash
./virgl-probe --flags=$((64 | 128 | 512))   # VENUS | NO_VIRGL | RENDER_SERVER
./virgl-probe --flags 704                   # same, space form
```

## Using the Nix flake

The probe folder is its own flake. From inside `tools/virgl-render-server-probe`:

```bash
nix develop                 # shell with gcc, virglrenderer, vulkan-loader, vulkan-tools
bash run-probe.sh venus-rs  # manual build+run (needs gcc, provided by the dev shell)

nix build                   # -> ./result/bin/virgl-probe (RPATH + render-server path baked in)
nix run . -- venus-rs       # run one mode
nix run . -- --flags=704    # VENUS | NO_VIRGL | RENDER_SERVER
```

`nix build`/`nix run` compile `probe.c` against nixpkgs' `virglrenderer` and wrap
the binary so `RENDER_SERVER_EXEC_PATH` and the library paths are set for you.
The devShell is what avoids the bare `gcc: command not found` you get running
`run-probe.sh` outside a shell that has a C toolchain.

The flake pins nixpkgs to the same revision the repo's `flake.lock` uses, so it
resolves against nixpkgs already in the Nix store (no fresh fetch). Because the
probe folder lives inside the repo, Nix only sees a flake whose files are
git-tracked — run `git add tools/virgl-render-server-probe` (stage the folder)
before `nix build`/`nix run`/`nix develop`, otherwise Nix errors with
"not tracked by Git".

The venus renderer needs a host Vulkan device. Point `VK_DRIVER_FILES` (or
`VK_ICD_FILENAMES`) at your host's AMD radv ICD and make sure `libvulkan.so.1` is
on the library path; the devShell supplies `vulkan-loader` for the latter.

## Modes

| Mode | Flags | What it isolates |
| --- | --- | --- |
| `venus` | `VENUS \| NO_VIRGL` | venus Vulkan in-process (no render server). Baseline for "venus works at all". |
| `venus-rs` | `VENUS \| NO_VIRGL \| RENDER_SERVER` | The key L2 path: venus in render-server mode, Vulkan-only. |
| `loftd` | `USE_EGL \| VENUS \| THREAD_SYNC \| ASYNC_FENCE_CB` (0x143) | Mirrors loftd `--gpu=virgl` today (no render server). |
| `loftd-rs` | loftd set `\| RENDER_SERVER` (0x343) | Mirrors loftd `--gpu=virgl` plus render server — the closest to what an L2 venus Vulkan app needs. |

## Interpreting the output

- Every mode starts by listing each Vulkan device this process can see (the
  render server forks with the same environment, so it sees the same set),
  tagged HARDWARE or SOFTWARE (llvmpipe/lavapipe/CPU). `max_size > 0` alone is
  NOT a device check — it is just the fixed size of the venus capset struct.
- **PASS** requires all three: at least one **HARDWARE** device visible (radv,
  virtio native context, …), `venus capset(4): max_size > 0`, and
  `context_create_with_flags(..., capset=4, "probe") => 0`. If only software
  devices are present the verdict is **FAIL - no HARDWARE Vulkan device** even
  when venus itself initializes, because that would be llvmpipe software
  rendering, not the real GPU. If the loader itself cannot be reached the
  verdict is **INCONCLUSIVE** — never PASS — so a green result always means a
  hardware device was actually seen.
- `init != 0` → this flag set is rejected by this virglrenderer build. Any
  virglrenderer diagnostics are printed on stderr as `[<mode>/virgl] …`
  (captured via `virgl_set_debug_callback`).
- `init => 0` but `max_size == 0` → the renderer started but the venus capset is
  absent: no usable host Vulkan device behind venus, or the render server failed
  to spawn/find a device. This is the "host Vulkan missing" signal.
- `loftd-rs` PASS while `venus-rs` FAILs (or vice versa) isolates whether the
  problem is the render-server split itself vs. the `USE_EGL`/native-context
  winsys flags in the loftd set.
- `(virgl_render_server process is running)` after a mode confirms the split
  actually spawned the render server; `(no virgl_render_server process …)` means
  it did not (or it exited).

## Capabilities & limits

- Proves the host-side venus/RENDER_SERVER path up to venus context creation. It
  does **not** submit guest Vulkan command streams — confirming an actual L2
  guest Vulkan app still requires the L2 guest to be running with a
  venus-capable virtio-gpu.
- The device list shows exactly which ICDs the loader exposes to the render
  server, so a wrong `VK_DRIVER_FILES`/`VK_ICD_FILENAMES` shows up as missing
  or software-only devices rather than a silent software fallback.
- Requires virglrenderer to be present in `/nix/store` (the repo builds it for
  libkrun) and that the L1 host can load `libvulkan.so.1`.
- Runs unsandboxed. The render-server `fork`/`execv`/`socketpair` calls are
  deliberately not restricted here; the probe is meant to be run directly on the
  L1 host, not under loftd's sandbox.
