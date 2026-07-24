# Consolidate Sunshine into the Headless release flake

## Purpose

Move the current Sunshine standard and CUDA prebuilt packaging from the standalone `zeroqn/sunshine` repository into the Headless repository so downstream Nix flakes can obtain Niri, Rio, `sunshine-bin`, and `sunshine-bin-cuda` from one root flake and one GitHub Release page.

## Scope

### Included

- Copy the current Sunshine packaging implementation into `sunshine/` under the Headless repository.
- Preserve the current pinned Sunshine source revision, Wayland DMA-BUF patch, standard source build, CUDA source build, and prebuilt reconstruction behavior.
- Expose Sunshine packages and source-build outputs from the Headless root flake.
- Preserve Sunshine's overlay behavior and NixOS capability adjustment.
- Publish standard and CUDA Sunshine archives on the existing rolling `main-build` release.
- Generate Sunshine-specific checksums and signed provenance.
- Extend package-scoped release metadata for standard and CUDA Sunshine.
- Document migration from `github:zeroqn/sunshine` to `github:zeroqn/headless`.
- Copy the current Sunshine repository state without importing its Git history.

### Excluded

- Keeping `github:zeroqn/sunshine` compatible after migration.
- A nested Sunshine flake or second lockfile under `sunshine/`.
- Updating Sunshine, CUDA, the prebuilt FFmpeg dependency, or the local Wayland patch.
- Automatically choosing the CUDA package based on host hardware.
- Adding systems beyond those already supported by the current packages.
- Archiving or deleting the standalone GitHub repository as part of the Headless code change.

## Repository layout

The root Headless flake owns all inputs, outputs, release metadata, updater logic, overlays, modules, and workflows.

The Sunshine-specific implementation lives under:

- `sunshine/prebuilt-package.nix`
- `sunshine/source-package.nix`
- `sunshine/build-deps.nix`
- `sunshine/sunshine-pr-5427.patch`

`source-package.nix` is the current standalone `vulkan.nix` under a name that describes its role rather than one enabled feature.

The standalone Sunshine files that duplicate repository-level infrastructure are not copied:

- `sunshine/flake.nix`
- `sunshine/flake.lock`
- `sunshine/release-assets.json`
- `sunshine/updater.sh`
- `sunshine/.github/workflows/build-release.yml`

## Root flake package contract

The Headless root flake keeps Niri as its default package and adds:

- `packages.x86_64-linux.sunshine`
- `packages.x86_64-linux.sunshine-bin`
- `packages.x86_64-linux.sunshine-bin-cuda`
- `packages.x86_64-linux.sunshineReleaseBuild`
- `packages.x86_64-linux.sunshineReleaseBuildCuda`

The package meanings are:

- `sunshine` and `sunshine-bin` are the standard prebuilt Sunshine package.
- `sunshine-bin-cuda` is the explicit CUDA-enabled prebuilt package.
- `sunshineReleaseBuild` is the standard source derivation used by release CI.
- `sunshineReleaseBuildCuda` is the CUDA source derivation used by release CI.

The root overlay exposes:

- `pkgs.sunshine` as the standard prebuilt package.
- `pkgs.sunshine-bin` as the same standard package.
- `pkgs.sunshine-bin-cuda` as the explicit CUDA package.
- Internal source-build attributes for release CI.

Importing the overlay never selects the CUDA variant automatically.

The root Nixpkgs import permits unfree packages so the CUDA source and prebuilt package closures can evaluate. This does not make the default Niri package, Rio, or standard Sunshine CUDA-enabled.

## NixOS module composition

The Headless root NixOS module continues to install the root overlay and also preserves Sunshine's wrapper capability adjustment.

When both conditions are true:

- `services.sunshine.enable`
- `services.sunshine.capSysAdmin`

The module forces the Sunshine wrapper capabilities to:

```text
cap_sys_admin,cap_sys_nice+p
```

When the privileged wrapper is not enabled, the module does not set this capability string.

The module does not automatically configure the Sunshine service or choose a Sunshine package. Downstream systems continue to use the upstream `services.sunshine` module and may explicitly select `pkgs.sunshine-bin-cuda` when required.

## Sunshine source-build preservation

The migrated standard and CUDA derivations preserve the current standalone behavior:

- The existing pinned LizardByte Sunshine source revision and source hash.
- The local `sunshine-pr-5427.patch` for multi-plane Wayland DMA-BUF export.
- The pinned prebuilt LizardByte FFmpeg bundle.
- Vulkan, PipeWire, Qt, udev, and systemd integration.
- The current NVENC API compatibility substitutions.
- Standard and CUDA build variants from one source definition.
- The current Sunshine wrapper and assets-path behavior.
- Disabled parallel building where required by the current derivation.

This consolidation is not a Sunshine upgrade.

## Prebuilt package preservation

Both Sunshine release archives remain complete Nix package output trees.

The migrated prebuilt derivation continues to:

- Unpack the release archive.
- Rewrite compiled-in Sunshine asset paths from the release builder's Nix store path.
- Replace the source-build wrapper with a wrapper targeting the downstream package output.
- Patch the systemd user service to the downstream Sunshine path.
- Preserve udev rules, systemd units, modules-load configuration, icons, desktop metadata, and web assets.
- Apply runtime library paths for the standard or CUDA dependency set.
- Remove the redundant systemd compatibility symlink that conflicts with Nix's systemd hook.
- Mark the package as native binary provenance.

The standard package must not gain CUDA runtime dependencies. The CUDA package must contain the CUDA runtime dependencies required by its source-built archive.

## Release architecture

### Build isolation

The Headless release workflow uses separate build jobs for:

- Niri and Rio.
- Standard and CUDA Sunshine.

Each job packages and verifies its complete asset group before uploading temporary workflow artifacts for publication.

The Sunshine group is atomic: if either the standard build or CUDA build fails, neither Sunshine variant is published by that run.

### Shared release publisher

A serialized publisher runs after the build jobs with `if: always()`.

It performs these operations:

1. Determine which package groups completed successfully.
2. Exit without changing the tag, release, or metadata if every group failed or was skipped.
3. Move the rolling `main-build` tag to the workflow commit when at least one group succeeded.
4. Create the GitHub Release if it does not exist.
5. Upload only the successful groups' owned assets with overwrite enabled.
6. Leave assets belonging to failed or skipped groups untouched.
7. Verify that unrelated release assets still exist after upload.
8. Regenerate package metadata while preserving entries for groups not published by the run.
9. Commit the metadata update once, after all successful uploads.

The workflow no longer deletes and recreates `main-build`, because deletion would erase assets owned by another independently failing package group.

### Concurrency

All release mutation uses one shared Headless release concurrency group.

Build jobs may execute independently, but tag movement, release creation, asset replacement, and metadata commits are serialized in one publisher. A newer workflow run must not cancel a run that has entered publication.

## Asset ownership

The Niri/Rio group owns:

- `niri-headless-main-x86_64-linux.tar.gz`
- `niri-headless-main-x86_64-linux.tar.gz.sha256`
- `rio-d656326-x86_64-linux.tar.gz`
- `rio-d656326-x86_64-linux.tar.gz.sha256`
- A Niri/Rio-specific Sigstore bundle.

The Sunshine group owns:

- `sunshine-main-x86_64-linux.tar.gz`
- `sunshine-main-x86_64-linux.tar.gz.sha256`
- `sunshine-main-cuda-x86_64-linux.tar.gz`
- `sunshine-main-cuda-x86_64-linux.tar.gz.sha256`
- A Sunshine-specific Sigstore bundle.

Group-specific attestation bundle names prevent one package group from overwriting the other group's provenance.

## Release metadata

The root `release-assets.json` remains package-scoped and adds:

- `packages.sunshine`
- `packages.sunshine-cuda`

Each Sunshine entry contains:

- Version.
- Source revision.
- System-keyed asset name.
- Release URL.
- Nix hash.

Conceptually:

```json
{
  "packages": {
    "niri": { "assets": {} },
    "rio": { "assets": {} },
    "sunshine": {
      "version": "main-build-<revision>",
      "revision": "<sunshine-source-revision>",
      "assets": {
        "x86_64-linux": {
          "name": "sunshine-main-x86_64-linux.tar.gz",
          "url": "...",
          "hash": "..."
        }
      }
    },
    "sunshine-cuda": {
      "version": "main-build-<revision>",
      "revision": "<sunshine-source-revision>",
      "assets": {
        "x86_64-linux": {
          "name": "sunshine-main-cuda-x86_64-linux.tar.gz",
          "url": "...",
          "hash": "..."
        }
      }
    }
  }
}
```

The updater supports partial package-group publication:

- A successful group refreshes only its package entries.
- A failed or skipped group retains its previous metadata unchanged.
- Standard and CUDA Sunshine always update together after the migration is active.
- If a Sunshine publication is requested but one Sunshine archive is missing, metadata generation fails.

This prevents metadata from falsely associating an unchanged older asset with a newer rolling-tag commit.

## Downstream migration

Existing downstream users replace:

```nix
sunshine-prebuilt.url = "github:zeroqn/sunshine";
```

with:

```nix
headless.url = "github:zeroqn/headless";
```

Direct package use becomes:

```nix
environment.systemPackages = [
  headless.packages.${pkgs.system}.sunshine-bin
];
```

CUDA use becomes:

```nix
environment.systemPackages = [
  headless.packages.${pkgs.system}.sunshine-bin-cuda
];
```

Overlay/module users import:

```nix
headless.nixosModules.default
```

and use `pkgs.sunshine` for the standard package or explicitly set the upstream Sunshine service package to `pkgs.sunshine-bin-cuda`.

The standalone `zeroqn/sunshine` repository is retired only after both Sunshine variants have been successfully published and verified from Headless. Repository archival or deletion is a separate explicit operation.

## Error handling

- A standard Sunshine build failure or CUDA Sunshine build failure prevents publication of both Sunshine variants for that run.
- A Sunshine failure does not block a successful Niri/Rio publication.
- A Niri/Rio failure does not block a successful Sunshine publication.
- If every build group fails, the workflow makes no shared-state changes.
- The publisher never deletes the shared release.
- Asset upload overwrites only the successful group's explicitly owned filenames.
- Missing one Sunshine variant aborts Sunshine metadata publication.
- Metadata for a non-published group remains unchanged.
- No source-build fallback is used by downstream prebuilt package outputs.

## Verification

### Root flake evaluation

- Existing Niri and Rio outputs remain unchanged.
- `packages.x86_64-linux.sunshine` evaluates.
- `packages.x86_64-linux.sunshine-bin` evaluates.
- `packages.x86_64-linux.sunshine-bin-cuda` evaluates.
- `packages.x86_64-linux.sunshineReleaseBuild` evaluates.
- `packages.x86_64-linux.sunshineReleaseBuildCuda` evaluates.
- The default package remains Niri.
- The overlay maps `pkgs.sunshine` to standard `sunshine-bin`, not CUDA.

### Sunshine source builds

- Build the standard Sunshine release derivation.
- Build the CUDA Sunshine release derivation.
- Verify expected executable, assets, desktop metadata, icons, systemd units, udev rules, and modules-load files.
- Run `sunshine --version` for both source-built outputs.

### Sunshine prebuilt reconstruction

- Create local archives from both source-build outputs.
- Build `sunshine-bin` and `sunshine-bin-cuda` against local HTTP-served archives and temporary metadata.
- Run `sunshine --version` for both reconstructed packages.
- Confirm neither package retains references to its source release output.
- Confirm the standard package closure has no CUDA runtime dependency.
- Confirm the CUDA package closure includes its expected CUDA runtime.

### Module behavior

- Evaluate the composed module with Sunshine disabled.
- Evaluate with Sunshine enabled and `capSysAdmin = false`.
- Evaluate with Sunshine enabled and `capSysAdmin = true`.
- Confirm the forced capability string appears only in the privileged case.
- Confirm the root overlay is installed once.

### Workflow behavior

Test fixture scenarios for:

- Both package groups succeed.
- Only Niri/Rio succeeds.
- Only Sunshine succeeds.
- Neither group succeeds.
- Standard Sunshine succeeds but CUDA fails.
- A Sunshine upload is missing one archive.
- Existing unrelated release assets survive each package-group upload.

### Static checks

- `nix flake check --no-build`
- `actionlint .github/workflows/build-release.yml`
- Shell syntax checks for updater and release helper scripts.
- Package-content assertions in the workflow.
- Local updater integration fixtures.
- `git diff --check`

## Performance, security, and accessibility

- Downstream users avoid rebuilding Sunshine and its CUDA variant.
- Build isolation prevents Sunshine's expensive CUDA build from blocking successful Niri/Rio publication.
- The publisher uses explicit asset ownership and serialization to avoid release races or accidental deletion.
- Existing Sunshine privilege behavior remains opt-in through the upstream service's `capSysAdmin` option.
- Desktop metadata, icons, service integration, web assets, and documentation remain in the prebuilt package outputs.
