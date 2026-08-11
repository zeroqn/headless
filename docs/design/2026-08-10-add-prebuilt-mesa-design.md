# Add prebuilt patched Mesa to the Headless release flake

## Summary

Build and distribute the pinned nixpkgs Mesa from the existing Headless flake with only `patches/mesa-headless-virtio-modifiers.patch` appended, and publish its runtime `out` output as a rolling `main-build` release asset. Downstream systems get the patched radeonsi (AMD virtio-gpu native context) without compiling Mesa locally.

The flake's pinned nixpkgs revision (`d3498f786f97ac0bded21b34bae0bf3809b45aa3`) already pins Mesa **26.1.5** with `amdgpu-virtio=true`, so no new source input is introduced. The Headless overlay and NixOS module replace nixpkgs's `pkgs.mesa` with the reconstructed prebuilt package while retaining a source-build attribute (`mesa-headless-release-build`) for release CI.

## Goals

- Deliver the patched Mesa runtime to downstream Headless consumers as a prebuilt, avoiding a local Mesa compilation.
- Pin Mesa 26.1.5 (via the pinned nixpkgs) so the virtio modifier fix is present.
- Preserve the exact nixpkgs Mesa source, version, Meson flags, dependencies, and output configuration, appending only the one patch.
- Publish an `x86_64-linux` archive, checksum, and Sigstore attestation on the shared rolling `main-build` release.
- Keep Mesa publication isolated from the Niri/Rio, Sunshine, Moonlight Qt, and Waypipe groups.
- Reconstruct a Nix package from the release archive without rebuilding Mesa downstream.
- Replace `pkgs.mesa` through the Headless overlay and NixOS module.
- Extend package-scoped release metadata and updater behavior for Mesa.
- Document direct flake-package and module-based downstream usage.

## Non-goals

- Publishing the `opencl`, `spirv2dxil`, `cross_tools`, or `debug` Mesa outputs. Binary publication is scoped to the runtime `out`; nixpkgs continues to provide the auxiliary outputs.
- Publishing 32-bit (`pkgsi686Linux`) Mesa.
- Supporting architectures beyond `x86_64-linux` in the initial change.
- Modifying Mesa source code beyond appending the one patch.
- Tracking a newer Mesa version than the pinned nixpkgs provides.
- Adding a separate GitHub Actions workflow for Mesa.
- Functional radeonsi/EGL verification in CI. That requires the AMD virtio-gpu native-context guest and is documented as a manual test.
- Changing the Headless default package from Niri.

## Source revision and version

- Package: nixpkgs `mesa`
- Version: `26.1.5` (pinned by the flake's nixpkgs lock; `pkgs/development/libraries/mesa/common.nix`)
- Source revision: `mesa-26.1.5`
- Patch: `patches/mesa-headless-virtio-modifiers.patch` (changes `info->kernel_has_modifiers = has_modifiers(fd) || (info->is_virtio && fd < 0)` to `... || info->is_virtio` in `src/amd/common/ac_gpu_info.c`)

The patch dry-runs clean against the pinned source tree (`Hunk #1 succeeded at 1555, offset 8`).

## Considered approaches

### Override the nixpkgs Mesa derivation

Use `pkgs.mesa.overrideAttrs` to append the patch while retaining the existing nixpkgs build configuration.

Advantages:

- Minimizes duplicated packaging.
- Retains the nixpkgs Meson flags (`amdgpu-virtio`, `freedreno-kmds`, glvnd, GBM, and the multi-output `out`/`opencl`/`spirv2dxil`/`cross_tools`/`debug` layout).
- Keeps future comparisons with nixpkgs straightforward.
- Matches the focused source-override pattern used by Waypipe, Moonlight Qt, and the standalone GRD packaging.

This is the selected approach.

### Copy the nixpkgs derivation

This would insulate the package definition from nixpkgs changes, but would duplicate a large, fast-moving packaging file and require maintaining it independently. Rejected.

### Ship a distro Mesa or a separate pinned Mesa source input

A distro Mesa cannot be reconstructed as a Nix package without re-linking, and pinning a separate Mesa source would diverge from the nixpkgs build configuration. Both rejected.

## Scope

- **In**: patched Mesa `out` (EGL, GLX, DRI, Vulkan, GBM backend, VA-API drivers, drirc, overlay-control scripts), built as `mesa-headless-release-build`; prebuilt reconstruction `mesa-headless-bin`; overlay replacement of `pkgs.mesa`; `build-mesa` job in the existing workflow; `mesa` publication group; `packages.mesa` release metadata.
- **Out**: `opencl`, `spirv2dxil`, `cross_tools`, `debug` outputs (grafted as passthru from nixpkgs per the approved scope); 32-bit Mesa; a separate workflow file; any Mesa change beyond the patch; functional GPU verification in CI.

## Source package

`mesa-headless-release-build` is derived from nixpkgs's Mesa package and overrides:

- `patches` — appends `./patches/mesa-headless-virtio-modifiers.patch`
- `passthru.sourceRevision = "mesa-26.1.5"` (release metadata)

The package retains the nixpkgs build inputs and behavior, including:

- `platforms = "x11,wayland"`, `gallium-drivers` with radeonsi, `vulkan-drivers` with RADV and virtio
- `amdgpu-virtio = true`, `freedreno-kmds = "msm,kgsl,virtio,wsl"`
- glvnd and GBM enabled
- All five outputs (`out`, `opencl`, `spirv2dxil`, `cross_tools`, `debug`)

The source output archived by release CI is the complete `out` tree. At minimum it contains:

- `lib/libEGL_mesa.so.0`, `lib/libGLX_mesa.so.0`
- `lib/libgallium-26.1.5.so`, `lib/libvulkan_radeon.so`, `lib/libvulkan_virtio.so`
- `lib/dri/radeonsi_dri.so` (symlink to `libdril_dri.so`)
- `lib/dri/radeonsi_drv_video.so`, `lib/dri/virtio_gpu_drv_video.so`
- `lib/gbm/dri_gbm.so`
- `share/glvnd/egl_vendor.d/50_mesa.json`
- `share/vulkan/icd.d/*.json`
- `share/drirc.d/*`
- `bin/mesa-overlay-control.py`, `bin/mesa-screenshot-control.py`

## Prebuilt package

Add `mesa/prebuilt-package.nix` to reconstruct the package from the published archive.

### The core mechanic

The archive embeds the build-time store path `/nix/store/<build-hash>-mesa-26.1.5/...` in three places:

- DT_RUNPATH entries on the shared libraries (fixed by auto-patchelf anyway)
- The JSON discovery files: `share/glvnd/egl_vendor.d/50_mesa.json` and `share/vulkan/icd.d/*.json` (`library_path`)
- A `share/drirc.d` string in ELF `.rodata` (e.g. in `lib/libEGL_mesa.so.0`)

Reconstruction succeeds because the new output path is the **same length**: the derivation is named `mesa-26.1.5` (`pname = "mesa"`, `version` from release metadata), so only the 32-character store hash differs. Rewriting `/nix/store/<oldhash>-mesa-26.1.5` to `$out` is therefore a binary-safe, fixed-length substitution.

### Derivation

The derivation uses:

- `fetchurl`
- `autoPatchelfHook`
- `autoAddDriverRunpath`
- Explicit runtime libraries mirroring the nixpkgs build inputs

It extracts the archive into `$out`, makes the tree writable, rewrites the build-time store path to `$out` across all files (including ELF binaries), and patches runtime references for the consuming nixpkgs revision.

Steps:

1. Extract the archive; `chmod -R u+w`.
2. Extract the build-time hash from `share/vulkan/icd.d/radeon_icd.x86_64.json`, then rewrite `/nix/store/<oldhash>-mesa-26.1.5` → `$out` across all files (binary-safe, same-length).
3. `autoPatchelfHook` with `runtimeDeps` and `appendRunpaths = ["$out/lib"]` so `libgallium-26.1.5.so` stays resolvable inside `$out`.
4. `autoAddDriverRunpath` for the `/run/opengl-driver` conventions.
5. `patchShebangs` on `bin/*.py`.

Runtime dependencies (mirroring the nixpkgs build inputs):

- `libdrm`, `libgbm`, `libglvnd`, `expat`
- `libx11`, `libxcb`, `libxext`, `libxfixes`, `libxrandr`, `libxshmfence`, `libxxf86vm`
- `wayland`
- `llvmPackages.libllvm`, `zstd`, `elfutils`, `lm_sensors`
- `libdisplay-info`, `libpng`, `libunwind`, `libva-minimal`
- `gcc-unwrapped`

Package metadata declares `mesa` as the main program (no `mainProgram`-relevant binary; kept consistent with nixpkgs), binary-native source provenance, and platform support constrained by available release metadata.

## Flake package interfaces

For each supported system, the root flake exposes:

- `packages.<system>.mesa`
- `packages.<system>.mesa-headless-bin`
- `packages.<system>.mesaReleaseBuild`

Behavior:

- `mesa` is the prebuilt package reconstructed from the shared Headless release.
- `mesa-headless-bin` aliases `mesa`.
- `mesaReleaseBuild` is the pinned source package used by release CI.
- The default package remains Niri.

## Overlay behavior

The root overlay exposes:

- `pkgs.mesa`
- `pkgs.mesa-headless-bin`
- `pkgs.mesa-headless-release-build`

`pkgs.mesa` is replaced with the Headless prebuilt package when release metadata contains an asset for the host system. `pkgs.mesa-headless-bin` is an explicit alias. The internal source-build attribute remains available independently of prebuilt asset availability.

The prebuilt replacement grafts the nixpkgs Mesa auxiliary outputs as passthru:

- `passthru.opencl`, `passthru.spirv2dxil`, `passthru.cross_tools`, `passthru.debug` → the nixpkgs Mesa outputs (per the approved scope; nixpkgs continues to supply them)

Replacing `pkgs.mesa` is intentional and matches the existing Sunshine, Moonlight, and Waypipe behavior: existing downstream references to `pkgs.mesa` consume the prebuilt package after importing the Headless overlay, and `hardware.graphics.package` (which defaults to `pkgs.mesa`) resolves to the patched package.

Known residual risk: the replacement is a single-output package. Packages that build against `pkgs.mesa`'s non-`out` outputs (e.g. `mesa.dev`) should use `pkgs.mesa-headless-release-build` or the nixpkgs mesa. This is documented rather than solved, consistent with the approved single-output publication scope.

## NixOS module behavior

The existing `nixosModules.default` continues to install the Headless overlay. Importing the module therefore makes `pkgs.mesa` resolve to the prebuilt package.

No Mesa-specific options or services are added. Because:

- `hardware.graphics.package` defaults to `pkgs.mesa`
- libglvnd is compiled with `DEFAULT_EGL_VENDOR_CONFIG_DIRS = "/run/opengl-driver/share/glvnd/egl_vendor.d:..."` via `addDriverRunpath.driverLink`
- vulkan-loader is compiled with `SYSCONFDIR = "${addDriverRunpath.driverLink}/share"` (ICD discovery under `/run/opengl-driver/share/vulkan/icd.d`)

enabling `hardware.graphics` on the AMD virtio native-context guest automatically uses the patched radeonsi for EGL, GLX, and Vulkan.

## Release workflow

Mesa is added to the existing `.github/workflows/build-release.yml`. No second workflow file is introduced.

### Build job

Add an independent `build-mesa` job alongside `build-niri-rio`, `build-sunshine`, `build-moonlight`, and `build-waypipe`.

The job:

1. Checks out the repository and installs Nix using the existing workflow conventions.
2. Builds `.#mesaReleaseBuild` into `result-mesa`.
3. Verifies the expected output structure (DRI driver, libgallium, ICD JSON, EGL vendor JSON, GBM backend).
4. Archives the complete source `out` result.
5. Produces a SHA-256 checksum.
6. Attests the archive using the existing Sigstore action pattern.
7. Uploads all Mesa publication inputs as `publish-mesa`.

The archive name is:

- `mesa-26.1.5-x86_64-linux.tar.gz`

The attestation bundle follows the package-group naming convention used by the existing workflow.

Build cost: this is a heavy, uncached source build (roughly an hour on `ubuntu-latest`). It runs on every main push, consistent with the other build jobs. The derivation is stable across pushes, so future runs could become cheap if a Nix store cache is added later; the first run pays the full cost.

### Publisher integration

The existing serialized publisher remains the only job that modifies `main-build`.

It is extended to:

- Depend on `build-mesa` without requiring that job to succeed.
- Download `publish-mesa` only when the Mesa build succeeds.
- Include `mesa` in the successful publication groups passed to the updater.
- Replace only Mesa-owned assets when publishing the Mesa group.
- Leave Mesa-owned assets untouched when the build fails or is skipped.
- Continue publishing successful Niri/Rio, Sunshine, Moonlight, and Waypipe groups independently.

The publisher still exits without changing the rolling release or metadata when every package group failed or was skipped.

## Release metadata

Extend `release-assets.json` with `packages.mesa` containing:

- Package version (`26.1.5`)
- Source revision (`mesa-26.1.5`)
- System-keyed asset metadata
- Archive name
- Archive URL
- Nix-compatible hash

Initial metadata supports only `x86_64-linux`. The archive prefix (`mesa-26.1.5-`) uniquely identifies Mesa-owned assets so the publisher can update them without touching other package groups.

## Updater behavior

Extend `updater.sh` with a `mesa` publication group.

The updater:

- Accepts `mesa` in `PUBLISH_GROUPS`.
- Collects the Mesa archive using its package-specific prefix.
- Requires all expected Mesa assets for the supported system before replacing Mesa metadata.
- Updates only `packages.mesa` when only Mesa is selected.
- Preserves existing Mesa metadata when Mesa is not selected.
- Supports mixed successful groups in one invocation.

The default group list includes Mesa once it is part of the release workflow.

## Failure behavior

- A failed Mesa build does not block successful Niri/Rio, Sunshine, Moonlight, or Waypipe publication.
- A failed or skipped Mesa build retains the previous Mesa archive, checksum, attestation, and metadata.
- A successful Mesa-only run refreshes only Mesa-owned assets and `packages.mesa` metadata.
- A missing or incomplete Mesa asset set must not produce partial Mesa metadata.
- The serialized publisher remains non-destructive for package groups not published by the current run.

## Downstream usage

With the Headless overlay or NixOS module imported, downstream packages use:

- `pkgs.mesa` (the patched prebuilt)

Without the overlay or module, downstream configurations use:

- `headless.packages.${pkgs.system}.mesa`
- `headless.packages.${pkgs.system}.mesa-headless-bin`

Source-build consumers use:

- `headless.packages.${pkgs.system}.mesaReleaseBuild`

Documentation states that the initial prebuilt release supports `x86_64-linux` only and that auxiliary Mesa outputs (`opencl`, `spirv2dxil`, `cross_tools`, `debug`) remain supplied by nixpkgs.

## Verification

### Evaluation and source build

- Run `nix flake check --no-build`.
- Build `.#mesaReleaseBuild`.
- Verify the `out` structure: `lib/dri/radeonsi_dri.so` symlink, `lib/libgallium-26.1.5.so`, `lib/libvulkan_radeon.so`, `share/vulkan/icd.d/radeon_icd.x86_64.json`, `share/glvnd/egl_vendor.d/50_mesa.json`, `lib/gbm/dri_gbm.so`.
- Confirm the patch applied (kernel modifier behavior in the radeonsi build).

### Prebuilt reconstruction

- Create a local archive from the source result.
- Provide temporary local release metadata for the archive.
- Build the reconstructed prebuilt package.
- Grep the entire reconstructed tree for any surviving build-time store hash; there must be zero matches.
- Confirm the reconstructed RUNPATH contains `$out/lib`.
- Confirm the reconstructed output does not reference the source release result.

### Overlay and module

- Assert `pkgs.mesa == pkgs.mesa-headless-bin` with the Headless overlay.
- Assert `pkgs.mesa != pkgs.mesa-headless-release-build`.
- Assert `pkgs.mesa.passthru.sourceRevision == "mesa-26.1.5"`.
- Evaluate a NixOS configuration importing the Headless module with `hardware.graphics.enable = true`.

### Metadata and workflow

- Test `updater.sh` against local GitHub API fixtures for Mesa-only and mixed-group publication.
- Verify omitted or failed Mesa publication retains existing metadata.
- Run `bash -n updater.sh`.
- Run `actionlint .github/workflows/build-release.yml`.
- Run `git diff --check`.

### Functional (manual, not CI)

On the AMD virtio-gpu native-context guest with the Headless overlay and `hardware.graphics.enable = true`:

- `eglQueryDmaBufModifiersEXT` reports the expected modifiers for radeonsi (previously zero).
- EGL, GLX, and Vulkan initialize through the patched radeonsi/RADV.

## Documented invariants and risks

- **Length invariant**: the reconstruction derivation must keep `pname = "mesa"` and `version = "26.1.5"` while the archive embeds `libgallium-26.1.5.so`. A version bump requires regenerating the archive in the same change (new metadata + new asset), since the same-length substitution is the mechanism that makes binary rewriting safe.
- **Single-output replacement**: packages building against `pkgs.mesa`'s non-`out` outputs should use `mesa-headless-release-build` or nixpkgs mesa; passthru grafting covers the scoped auxiliary outputs.
- The `out` tree is roughly 266 MB; the archive is roughly 90 MB.

## Approved decisions

- Override the nixpkgs Mesa derivation rather than copying it, pinning Mesa 26.1.5 via the existing nixpkgs lock.
- Replace `pkgs.mesa` through the Headless overlay, graft nixpkgs auxiliary outputs (`opencl`, `spirv2dxil`, `cross_tools`, `debug`) as passthru, and expose `pkgs.mesa-headless-bin` explicitly.
- Publish only the runtime `out` output.
- Add `build-mesa` to the existing release workflow rather than creating a new workflow.
- Publish Mesa as an isolated group through the existing serialized, non-destructive publisher.
- Run the Mesa build on every main push (consistent with the other build jobs).
- Support `x86_64-linux` only in the initial release.
