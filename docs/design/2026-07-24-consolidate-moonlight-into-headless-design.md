# Consolidate Moonlight Qt into the Headless release flake

## Summary

Move the current Moonlight Qt source-build and prebuilt packaging from the standalone `zeroqn/moonlight-qt` repository into the Headless repository so downstream Nix flakes can obtain Niri, Rio, Sunshine, and Moonlight Qt from one root flake and one rolling GitHub Release page.

Moonlight becomes an independently buildable and publishable package group. A Moonlight failure must not block fresh Niri/Rio or Sunshine assets, and failures in those groups must not replace or remove the last successful Moonlight asset or metadata.

## Goals

- Copy the current Moonlight Qt prebuilt packaging implementation into `moonlight/` under the Headless repository.
- Preserve the pinned Moonlight Qt revision `1d1fe1aac39dd414ed825fe834b84a0e4eea8338`.
- Preserve the current source override, submodule fetching, cleared patch list, archive layout, runtime dependencies, auto-patchelf behavior, Qt wrapping, and `QML_DISABLE_DISK_CACHE=1` workaround.
- Expose Moonlight Qt prebuilt and source-build outputs from the Headless root flake.
- Preserve Moonlight's overlay and NixOS module behavior through the Headless root overlay and module.
- Publish Moonlight Qt on the existing rolling `main-build` release.
- Keep Moonlight publication isolated from the Niri/Rio and Sunshine package groups.
- Extend package-scoped release metadata and updater behavior for Moonlight Qt.
- Document downstream migration from `github:zeroqn/moonlight-qt` to `github:zeroqn/headless`.
- Copy the current Moonlight repository state without importing its Git history.

## Non-goals

- Keeping `github:zeroqn/moonlight-qt` compatible after migration.
- Archiving or deleting the standalone GitHub repository as part of the Headless code change.
- Updating Moonlight Qt or changing its source revision, build flags, dependencies, or patches.
- Adding systems beyond those already supported by the current package metadata.
- Changing the Headless default package from Niri.
- Adding a nested Moonlight flake or second lockfile under `moonlight/`.
- Automatically configuring Moonlight or Sunshine for downstream systems.
- Coupling Moonlight publication success to Sunshine, Niri, or Rio.

## Repository layout

The Headless root flake continues to own all inputs, outputs, release metadata, updater logic, overlays, modules, and workflows.

The consolidation adds:

- `moonlight/prebuilt-package.nix`

The implementation is copied from the standalone `prebuilt-package.nix` without changing its package behavior.

The standalone files that duplicate repository-level infrastructure are not copied:

- `flake.nix`
- `flake.lock`
- `release-assets.json`
- `updater.sh`
- `.github/workflows/build-release.yml`

The Moonlight source derivation remains a small override in the Headless root `flake.nix`; a separate source-package file is not needed for the current implementation.

## Root flake package contract

The Headless root flake keeps Niri as its default package and adds these per-system outputs:

- `moonlight-qt`
- `moonlight-qt-bin`
- `moonlightReleaseBuild`

Their meanings are:

- `moonlight-qt` is the prebuilt Moonlight Qt package reconstructed from the shared Headless rolling release.
- `moonlight-qt-bin` is an alias of `moonlight-qt`.
- `moonlightReleaseBuild` is the pinned source derivation used by release CI.

The root overlay adds:

- `pkgs.moonlight-qt`
- `pkgs.moonlight-qt-bin`
- `pkgs.moonlight-headless-release-build`

The source-build overlay attribute is internal release infrastructure. The public source-build flake output is `moonlightReleaseBuild`.

The overlay exposes prebuilt Moonlight attributes only when release metadata contains an asset for the host system. The source-build attribute remains available independently of prebuilt asset presence.

The supported-system behavior remains consistent with the Headless package metadata contract. This change introduces no new architecture or platform support.

## NixOS module behavior

The Headless root `nixosModules.default` continues to install `self.overlays.default`.

That preserves the standalone Moonlight module behavior: downstream modules that import the Headless module can install `pkgs.moonlight-qt` without separately applying the overlay.

Moonlight requires no package-specific NixOS options or service configuration in this repository. The existing Sunshine capability adjustment remains unchanged and continues to be conditional on the upstream Sunshine service options.

## Source-build preservation

`moonlightReleaseBuild` is based on `pkgs.moonlight-qt.overrideAttrs` and preserves the standalone source override:

- Owner: `moonlight-stream`
- Repository: `moonlight-qt`
- Revision: `1d1fe1aac39dd414ed825fe834b84a0e4eea8338`
- Version: `1d1fe1a`
- Source hash: the current standalone source hash
- Submodules: enabled
- Patches: cleared with `patches = []`

No Moonlight update is part of this consolidation.

## Prebuilt package preservation

The prebuilt package continues to:

- Download the system-specific asset selected from release metadata.
- Extract a dereferenced gzip-compressed tar archive.
- Copy the complete release output into the package output.
- Rename `bin/.moonlight-wrapped` to `bin/moonlight` before Qt wrapping.
- Use `autoPatchelfHook` and `qt6.wrapQtAppsHook`.
- Preserve the existing runtime dependency set.
- Set `QML_DISABLE_DISK_CACHE=1` in the generated wrapper.
- Keep `moonlight` as `meta.mainProgram`.

The archive remains a complete Nix output tree rather than a reduced binary-only artifact, preserving desktop integration and other installed resources from the source package.

## Release metadata

The shared `release-assets.json` adds a package-scoped Moonlight entry:

```json
{
  "packages": {
    "moonlight": {
      "version": "main-build-main",
      "revision": "1d1fe1aac39dd414ed825fe834b84a0e4eea8338",
      "assets": {
        "x86_64-linux": {
          "name": "moonlight-qt-main-x86_64-linux.tar.gz",
          "url": "https://github.com/zeroqn/headless/releases/download/main-build/moonlight-qt-main-x86_64-linux.tar.gz",
          "hash": "sha256-..."
        }
      }
    }
  }
}
```

The exact initial hash is generated from the published Headless release asset rather than copied from an asset hosted by the standalone repository.

The updater accepts `moonlight` as a publication group and refreshes only `packages.moonlight` when that group is selected. Other package metadata remains byte-for-byte semantically unchanged by a Moonlight-only refresh.

Moonlight asset discovery selects names beginning with `moonlight-qt-main-` and ending with `.tar.gz`. Checksum and attestation files are not treated as package archives.

The package version follows the existing rolling-release convention based on the release tag and short target commit. The package revision records the pinned upstream Moonlight revision, not the Headless workflow commit.

## Release workflow

### Independent build job

Add a `build-moonlight` job alongside `build-niri-rio` and `build-sunshine`.

The job:

1. Checks out the Headless repository.
2. Installs Nix and enables the existing Nix cache action.
3. Builds `.#moonlightReleaseBuild` with a dedicated result link.
4. Verifies the expected Moonlight executable exists in the source output.
5. Creates `moonlight-qt-main-x86_64-linux.tar.gz` by dereferencing the complete result tree.
6. Generates the matching SHA-256 checksum file.
7. Attests the Moonlight archive with the same GitHub artifact-attestation mechanism used by the other groups.
8. Writes a package-group-specific Sigstore bundle asset.
9. Uploads all publication inputs as the `publish-moonlight` workflow artifact.

The Moonlight group publishes:

- `moonlight-qt-main-x86_64-linux.tar.gz`
- `moonlight-qt-main-x86_64-linux.tar.gz.sha256`
- `moonlight-main-build-x86_64-linux.sigstore.json`

### Serialized publisher

The existing publisher remains the only job that mutates the rolling tag, GitHub release, or checked-in metadata.

It gains `build-moonlight` as an optional dependency and attempts to download `publish-moonlight` without making that artifact mandatory for other groups.

The publisher:

1. Detects which package-group artifacts are present.
2. Exits without changing the tag, release, or metadata if every group failed or was skipped.
3. Confirms the workflow commit is still the current `main` commit.
4. Force-updates the rolling `main-build` tag only after the stale-run check passes.
5. Uploads assets from successful groups without deleting unrelated existing release assets.
6. Runs the updater with exactly the successful group names.
7. Commits and pushes metadata only when `release-assets.json` changed.

The existing publisher concurrency group continues to serialize release mutation.

## Failure behavior

Publication is non-destructive and package-group scoped.

- A failed or skipped Moonlight build retains the previous Moonlight archive, checksum, attestation, and metadata.
- A successful Moonlight build may publish even when Niri/Rio or Sunshine fails.
- Successful Niri/Rio or Sunshine groups may publish when Moonlight fails.
- A Moonlight-only successful run updates only Moonlight release files and `packages.moonlight` metadata.
- If no package group succeeds, the rolling release and metadata remain unchanged.
- A stale workflow run cannot update the rolling tag or release.

This preserves the partial-publication guarantees introduced for Sunshine while adding Moonlight as a third independent group.

## Data flow

1. The root flake constructs `moonlightReleaseBuild` from the pinned upstream source.
2. The Moonlight CI job builds the derivation and packages its dereferenced output.
3. The job produces an archive, checksum, and attestation bundle in `publish-moonlight`.
4. The serialized publisher discovers the successful Moonlight group.
5. The publisher uploads Moonlight files to the shared Headless `main-build` release without deleting failed or skipped groups' files.
6. `updater.sh` reads the release, hashes the Moonlight archive, and updates only `packages.moonlight`.
7. Downstream Headless evaluations fetch that archive and reconstruct `pkgs.moonlight-qt` with the existing auto-patchelf and Qt wrapper behavior.

## Downstream migration

A downstream flake changes its input from:

```nix
inputs.moonlight-qt.url = "github:zeroqn/moonlight-qt";
```

to:

```nix
inputs.headless.url = "github:zeroqn/headless";
```

A module import changes from:

```nix
moonlight-qt.nixosModules.default
```

to:

```nix
headless.nixosModules.default
```

Existing package use through the overlay remains:

```nix
environment.systemPackages = [ pkgs.moonlight-qt ];
```

Without the overlay, use:

```nix
environment.systemPackages = [
  headless.packages.${pkgs.system}.moonlight-qt
];
```

Source-build consumers change from the standalone flake's generic output:

```nix
moonlight-qt.packages.${system}.releaseBuild
```

to the package-specific Headless output:

```nix
headless.packages.${system}.moonlightReleaseBuild
```

The documentation states that continued compatibility, archival, or deletion of the standalone Moonlight repository is outside this change.

## Verification

Verification covers source behavior, prebuilt reconstruction, overlay/module behavior, updater isolation, workflow structure, and static checks.

### Package checks

- Build `.#moonlightReleaseBuild` at the preserved revision.
- Confirm the source result contains the expected Moonlight executable and package resources.
- Reconstruct and build `.#moonlight-qt` from a local release metadata fixture.
- Confirm the reconstructed package contains `bin/moonlight`.
- Confirm the generated wrapper sets `QML_DISABLE_DISK_CACHE=1`.
- Confirm auto-patchelf resolves the preserved runtime dependency set.

### Flake and module checks

- Assert `pkgs.moonlight-qt == pkgs.moonlight-qt-bin`.
- Assert `pkgs.moonlight-qt.meta.mainProgram == "moonlight"`.
- Assert Headless keeps Niri as `packages.default`.
- Evaluate the root NixOS module and confirm it installs the root overlay.
- Confirm adding Moonlight does not alter the conditional Sunshine capability behavior.

### Metadata updater fixtures

Exercise fixtures for:

- Moonlight-only publication.
- Niri/Rio and Moonlight publication in one run.
- Sunshine and Moonlight publication in one run.
- All groups publishing in one run.
- Failed or skipped Moonlight preserving its previous metadata.
- Moonlight asset selection excluding checksum and attestation files.
- Other package groups remaining unchanged during a Moonlight-only refresh.

### Workflow and static checks

- Validate the GitHub Actions workflow with `actionlint`.
- Check shell syntax for `updater.sh`.
- Run Nix formatting and flake evaluation checks.
- Run `git diff --check`.
- Inspect the final diff to confirm no standalone lockfile, updater, or workflow was copied under `moonlight/`.

## Accessibility and performance

The consolidation does not change Moonlight's user interface or accessibility behavior.

Runtime performance behavior is preserved by retaining the current source revision, source package defaults, complete output archive, dependency set, and wrapper configuration. The design does not add runtime indirection beyond the existing Nix wrapper and prebuilt reconstruction.

CI performance remains isolated by building Moonlight in its own job. Moonlight does not lengthen the critical build path of Niri/Rio or Sunshine, although the serialized publisher waits for all package-group jobs to reach a terminal state before deciding which groups to publish.

## Acceptance criteria

- Headless exposes prebuilt `moonlight-qt` and `moonlight-qt-bin` packages that are aliases of the same reconstructed package.
- Headless exposes `moonlightReleaseBuild` at the preserved upstream revision.
- Importing `headless.nixosModules.default` makes `pkgs.moonlight-qt` available.
- Moonlight uses the Headless `main-build` release asset and package-scoped metadata.
- Moonlight builds and publishes independently of Niri/Rio and Sunshine.
- A failed or skipped Moonlight group leaves its previous release files and metadata intact.
- Successful package groups continue to publish through one serialized, stale-run-protected coordinator.
- The prebuilt package preserves the current QML disk-cache workaround and runtime behavior.
- Migration documentation gives both overlay-based and direct-package usage.
- All package, metadata, workflow, shell, Nix, and static checks pass.
