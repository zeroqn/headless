# Add prebuilt Waypipe to the Headless release flake

## Summary

Build and distribute a pinned Waypipe revision from the existing Headless flake and rolling `main-build` release. Waypipe becomes an independently buildable and publishable package group alongside Niri/Rio, Sunshine, and Moonlight Qt.

The Headless overlay and NixOS module replace nixpkgs's `pkgs.waypipe` with the reconstructed prebuilt package while retaining an explicit `pkgs.waypipe-bin` alias and a source-build output for release CI.

## Goals

- Pin Waypipe commit `1ac039b4d50e2658d284e750c182266cc00efe74` so the fix for nonintegral viewport crops is included.
- Preserve the feature set and dependency configuration of the nixpkgs Waypipe package.
- Build Waypipe from source in the existing `.github/workflows/build-release.yml` workflow.
- Publish an `x86_64-linux` archive, checksum, and Sigstore attestation on the shared rolling `main-build` release.
- Keep Waypipe publication independent from Niri/Rio, Sunshine, and Moonlight Qt publication.
- Reconstruct a Nix package from the release archive without rebuilding Waypipe downstream.
- Expose Waypipe through the Headless flake, overlay, and NixOS module.
- Extend package-scoped release metadata and updater behavior for Waypipe.
- Document direct flake-package and module-based downstream usage.

## Non-goals

- Adding a Waypipe service or NixOS configuration options.
- Configuring SSH or automatically deploying Waypipe to remote hosts.
- Publishing non-NixOS, static, or cross-architecture binaries.
- Supporting architectures beyond `x86_64-linux` in the initial change.
- Modifying Waypipe source code beyond selecting the pinned revision.
- Automatically tracking Waypipe's latest branch or waiting for a later tagged release.
- Adding a separate GitHub Actions workflow for Waypipe.
- Changing the Headless default package from Niri.

## Source revision and version

The source build uses:

- Repository: `https://gitlab.freedesktop.org/mstoeckl/waypipe`
- Revision: `1ac039b4d50e2658d284e750c182266cc00efe74`
- Upstream project version: `0.11.0`
- Package version: `0.11.0-unstable-2026-06-17`

The selected commit fixes a panic triggered by nonintegral Wayland viewport crops. Pinning the commit guarantees that the fix is present instead of depending on the revision currently packaged by nixpkgs.

## Considered approaches

### Override the nixpkgs Waypipe derivation

Use `pkgs.waypipe.overrideAttrs` to replace its source, version, and Cargo vendor dependency set while retaining the existing nixpkgs build configuration.

Advantages:

- Minimizes duplicated packaging.
- Retains nixpkgs's Meson, Rust, man-page, feature, and dependency configuration.
- Keeps future comparisons with nixpkgs straightforward.
- Matches the focused source-override pattern already used in Headless where appropriate.

Trade-off:

- Structural changes to the nixpkgs Waypipe derivation may require updating the override.

This is the selected approach.

### Copy the nixpkgs derivation

This would insulate the package definition from structural changes in nixpkgs, but it would duplicate packaging and require maintaining dependency and build-system changes independently. It is rejected unless a focused override proves impractical during implementation.

### Add Waypipe as a flake source input and independently package it

Waypipe does not expose a reusable flake package interface at this revision, so Headless would still need to reproduce the nixpkgs derivation. This adds an input without reducing packaging complexity and is rejected.

## Source package

The release source package is derived from nixpkgs's Waypipe package and overrides:

- `src`
- `version`
- `cargoDeps`
- Source-revision metadata needed by release metadata generation

The package retains the nixpkgs Waypipe build inputs and behavior, including:

- Rust Waypipe implementation
- Meson and Ninja build
- Generated `waypipe.1` manual page
- LZ4 compression
- Zstandard compression
- GBM fallback
- DMA-BUF support through Vulkan
- FFmpeg video transport
- Runtime dependencies for GBM, FFmpeg, and Vulkan

The source output is the complete tree archived by release CI. At minimum it contains:

- `bin/waypipe`
- `share/man/man1/waypipe.1`

## Prebuilt package

Add `waypipe/prebuilt-package.nix` to reconstruct the package from the published archive.

The derivation uses:

- `fetchurl`
- `autoPatchelfHook`
- `autoAddDriverRunpath`
- Explicit runtime libraries matching the source package

It extracts the archive, copies the complete result into `$out`, makes the copied tree writable where necessary, and patches runtime references for the consuming nixpkgs revision.

Package metadata declares `waypipe` as the main program, binary-native source provenance, and platform support constrained by available release metadata.

## Flake package interfaces

For each supported system, the root flake exposes:

- `packages.<system>.waypipe`
- `packages.<system>.waypipe-bin`
- `packages.<system>.waypipeReleaseBuild`

Behavior:

- `waypipe` is the prebuilt package reconstructed from the shared Headless release.
- `waypipe-bin` aliases `waypipe`.
- `waypipeReleaseBuild` is the pinned source package used by release CI.
- The default package remains Niri.

## Overlay behavior

The root overlay exposes:

- `pkgs.waypipe`
- `pkgs.waypipe-bin`
- `pkgs.waypipe-headless-release-build`

`pkgs.waypipe` is replaced with the Headless prebuilt package when release metadata contains an asset for the host system. `pkgs.waypipe-bin` is an explicit alias. The internal source-build attribute remains available independently of prebuilt asset availability.

Replacing `pkgs.waypipe` is intentional and matches the existing Sunshine and Moonlight behavior. Existing downstream references to `pkgs.waypipe` consume the prebuilt package after importing the Headless overlay.

## NixOS module behavior

The existing `nixosModules.default` continues to install the Headless overlay. Importing the module therefore makes `pkgs.waypipe` resolve to the prebuilt package.

No Waypipe-specific options, services, SSH settings, or remote-host deployment logic are added.

## Release workflow

Waypipe is added to the existing `.github/workflows/build-release.yml`. No second workflow file is introduced.

### Build job

Add an independent `build-waypipe` job alongside `build-niri-rio`, `build-sunshine`, and `build-moonlight`.

The job:

1. Checks out the repository and installs Nix using the existing workflow conventions.
2. Builds `.#waypipeReleaseBuild` into `result-waypipe`.
3. Verifies the executable and manual page.
4. Runs a basic version command from the source result.
5. Archives the complete source result.
6. Produces a SHA-256 checksum.
7. Attests the archive using the existing Sigstore action pattern.
8. Uploads all Waypipe publication inputs as `publish-waypipe`.

The archive name is:

- `waypipe-1ac039b4-x86_64-linux.tar.gz`

The attestation bundle follows the package-group naming convention used by the existing workflow. Its exact filename is release plumbing rather than a public package interface.

### Publisher integration

The existing serialized publisher remains the only job that modifies `main-build`.

It is extended to:

- Depend on `build-waypipe` without requiring that job to succeed.
- Download `publish-waypipe` only when the Waypipe build succeeds.
- Include `waypipe` in the successful publication groups passed to the updater.
- Replace only Waypipe-owned assets when publishing the Waypipe group.
- Leave Waypipe-owned assets untouched when the build fails or is skipped.
- Continue publishing successful Niri/Rio, Sunshine, and Moonlight groups independently.

The publisher still exits without changing the rolling release or metadata when every package group failed or was skipped.

## Release metadata

Extend `release-assets.json` with `packages.waypipe` containing:

- Package version
- Full source revision
- System-keyed asset metadata
- Archive name
- Archive URL
- Nix-compatible hash

Initial metadata supports only `x86_64-linux`. The archive prefix uniquely identifies Waypipe-owned assets so the publisher can update them without touching other package groups.

## Updater behavior

Extend `updater.sh` with a `waypipe` publication group.

The updater:

- Accepts `waypipe` in `PUBLISH_GROUPS`.
- Collects the Waypipe archive using its package-specific prefix.
- Requires all expected Waypipe assets for the supported system before replacing Waypipe metadata.
- Updates only `packages.waypipe` when only Waypipe is selected.
- Preserves existing Waypipe metadata when Waypipe is not selected.
- Supports mixed successful groups in one invocation.

The default group list includes Waypipe once it is part of the release workflow.

## Failure behavior

- A failed Waypipe build does not block successful Niri/Rio, Sunshine, or Moonlight publication.
- A failed or skipped Waypipe build retains the previous Waypipe archive, checksum, attestation, and metadata.
- A successful Waypipe-only run refreshes only Waypipe-owned assets and `packages.waypipe` metadata.
- A missing or incomplete Waypipe asset set must not produce partial Waypipe metadata.
- The serialized publisher remains non-destructive for package groups not published by the current run.

## Downstream usage

With the Headless overlay or NixOS module imported, downstream packages use:

- `pkgs.waypipe`
- `pkgs.waypipe-bin`

Without the overlay or module, downstream configurations use:

- `headless.packages.${pkgs.system}.waypipe`
- `headless.packages.${pkgs.system}.waypipe-bin`

Source-build consumers use:

- `headless.packages.${pkgs.system}.waypipeReleaseBuild`

Documentation states that the initial prebuilt release supports `x86_64-linux` only.

## Verification

### Evaluation and source build

- Run `nix flake check --no-build`.
- Build `.#waypipeReleaseBuild`.
- Verify `bin/waypipe` is executable.
- Verify `share/man/man1/waypipe.1` exists.
- Run `waypipe --version` from the source result.
- Confirm expected LZ4, Zstandard, GBM, Vulkan/DMA-BUF, and FFmpeg functionality through build output and runtime linkage.

### Prebuilt reconstruction

- Create a local archive from the source result.
- Provide temporary local release metadata for the archive.
- Build the reconstructed prebuilt package.
- Run `waypipe --version` from the reconstructed package.
- Verify the manual page is present.
- Confirm the reconstructed output does not reference the source release result.

### Overlay and module

- Assert `pkgs.waypipe == pkgs.waypipe-bin` with the Headless overlay.
- Assert the package main program is `waypipe`.
- Evaluate a NixOS configuration importing the Headless module and referencing `pkgs.waypipe`.

### Metadata and workflow

- Test `updater.sh` against local GitHub API fixtures for Waypipe-only and mixed-group publication.
- Verify omitted or failed Waypipe publication retains existing metadata.
- Run `bash -n updater.sh`.
- Run `actionlint .github/workflows/build-release.yml`.
- Run `git diff --check`.

## Approved decisions

- Pin the linked fix commit rather than tracking nixpkgs's stable Waypipe package.
- Override the nixpkgs derivation instead of copying it initially.
- Replace `pkgs.waypipe` through the Headless overlay and expose `pkgs.waypipe-bin` explicitly.
- Add `build-waypipe` to the existing release workflow rather than creating a new workflow.
- Publish Waypipe as an isolated group through the existing serialized, non-destructive publisher.
- Support `x86_64-linux` only in the initial release.
