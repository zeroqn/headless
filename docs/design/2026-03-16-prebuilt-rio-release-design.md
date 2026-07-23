# Prebuilt Rio release design

## Purpose

Add a reproducible prebuilt Rio terminal package to the Headless repository so downstream Nix flakes can install the linked Rio development revision without compiling it locally.

## Scope

### Included

- Pin Rio to commit `d656326020ffe5959e221af7a7d1d8d82a6ab2db`.
- Build Rio for `x86_64-linux` in the existing Headless release workflow.
- Publish the Rio archive, checksum, and Sigstore provenance on the rolling `main-build` release alongside Niri.
- Expose a prebuilt Rio package from the Headless flake without changing the default Niri package.
- Preserve Rio's executable, terminfo, desktop entry, icon, and manuals.
- Record independent Rio release URL, hash, version, and source revision metadata.

### Excluded

- Tracking Rio's upstream `main` branch automatically.
- Replacing `pkgs.rio` globally through the Headless overlay.
- Architectures or operating systems other than `x86_64-linux`.
- Building `.deb`, `.rpm`, AppImage, or other distribution formats.
- Modifying Rio source or the behavior introduced by the linked commit.

## Chosen approach

Use Rio's upstream flake pinned to the exact commit and merge its package outputs into one release tree.

Rio already provides the Rust toolchain and Nix build definition needed by this development revision. Reusing that definition avoids maintaining a separate Cargo dependency hash and avoids coupling the build to the older Rust compiler used by the currently packaged nixpkgs Rio release.

Alternatives not selected:

- Overriding nixpkgs `rio` would require commit-specific source and Cargo hashes and may require Rust toolchain adjustments.
- Building directly with Cargo in GitHub Actions would duplicate upstream packaging and make runtime dependencies and installed data files more fragile.

## Flake architecture

Add a `rio-src` flake input pinned to commit `d656326020ffe5959e221af7a7d1d8d82a6ab2db`.

Keep these existing interfaces unchanged:

- `packages.x86_64-linux.default`
- Existing Niri package outputs
- Existing `pkgs.niri` overlay behavior

Add these interfaces:

- `packages.x86_64-linux.rioReleaseBuild`
  - Source-built Rio package prepared for release CI.
  - Combines Rio's main output and terminfo output into one directory.
- `packages.x86_64-linux.rio-bin`
  - Reconstructs a usable Rio package from the published archive.
- Overlay package `pkgs.rio-headless-bin`
  - Exposes the prebuilt package without overriding nixpkgs `pkgs.rio`.

The default package remains Niri.

## Release archive contract

The Rio release-build derivation combines the upstream package outputs into one self-contained tree containing:

- `bin/rio`
- `share/terminfo`
- `share/applications`
- `share/icons`
- `share/man`

Asset names include the pinned short revision:

- `rio-d656326-x86_64-linux.tar.gz`
- `rio-d656326-x86_64-linux.tar.gz.sha256`

The attestation bundle is shared by the Niri and Rio archive subjects and uses a neutral release-wide name:

- `main-build-x86_64-linux.sigstore.json`

The downstream Rio derivation unpacks the release tree, applies `autoPatchelfHook`, preserves all data files, declares native binary provenance, and sets `meta.mainProgram = "rio"`.

## Release workflow

The existing release job performs the following operations in order:

1. Build `.#releaseBuild` for Niri.
2. Build `.#rioReleaseBuild` for Rio.
3. Archive and checksum each package independently.
4. Generate one provenance attestation covering both `.tar.gz` subjects.
5. Copy the generated Sigstore bundle to `main-build-x86_64-linux.sigstore.json`.
6. Update the rolling `main-build` tag.
7. Replace the existing rolling release.
8. Upload both archives, both checksums, and the shared attestation bundle.
9. Regenerate release metadata.
10. Commit updated metadata only after successful publication.

The release is atomic at the job level: a Rio build, packaging, checksum, or attestation failure occurs before the rolling release is replaced. This prevents publishing a partial Niri-only or Rio-only release with mismatched metadata.

## Release metadata

Replace the single Niri-specific asset mapping with package-scoped metadata. Each package has assets keyed by system and independent version/source information.

Conceptually:

```json
{
  "owner": "zeroqn",
  "repo": "headless",
  "release": {
    "tag": "main-build"
  },
  "packages": {
    "niri": {
      "version": "...",
      "revision": "...",
      "assets": {
        "x86_64-linux": {
          "name": "...",
          "url": "...",
          "hash": "..."
        }
      }
    },
    "rio": {
      "version": "0.4.12-d656326",
      "revision": "d656326020ffe5959e221af7a7d1d8d82a6ab2db",
      "assets": {
        "x86_64-linux": {
          "name": "rio-d656326-x86_64-linux.tar.gz",
          "url": "...",
          "hash": "..."
        }
      }
    }
  }
}
```

The updater identifies package assets by explicit package-specific prefixes rather than treating every `.tar.gz` as Niri. Existing Niri output behavior remains unchanged after adapting its internal metadata lookup.

## Downstream usage

Downstream flakes can consume Rio directly without compiling it:

```nix
environment.systemPackages = [
  headless.packages.${pkgs.system}.rio-bin
];
```

Consumers using the Headless overlay may use:

```nix
environment.systemPackages = [
  pkgs.rio-headless-bin
];
```

The design deliberately does not replace `pkgs.rio`, preventing an unrelated Rio override from surprising users who only imported the Headless overlay for Niri.

## Error handling

- Missing Rio source package outputs fail flake evaluation or the release build.
- Missing expected archive content fails package-content checks before release replacement.
- A failed Rio build, checksum, or attestation stops the workflow before tag/release mutation.
- The metadata updater fails if either expected Niri or Rio archive is absent.
- The downstream derivation fails if the release hash or archive structure does not match metadata.

No fallback to source compilation is provided. A prebuilt package failure must remain visible instead of silently increasing downstream build cost or changing provenance.

## Verification

### Flake evaluation

- Existing Niri outputs still evaluate unchanged.
- `packages.x86_64-linux.rio-bin` evaluates.
- `packages.x86_64-linux.rioReleaseBuild` evaluates.
- The overlay exposes `rio-headless-bin` without replacing nixpkgs `rio`.

### Build and package content

- Build `.#rioReleaseBuild`.
- Verify the merged output contains:
  - `bin/rio`
  - Rio and xterm-rio terminfo entries
  - Desktop metadata
  - Application icon
  - Manuals
- Build the prebuilt derivation against a locally generated archive.
- Run `rio --version` as a non-graphical smoke check.
- Confirm the reconstructed package does not retain references to the CI build's Rio output.

### Workflow and metadata

- Run `actionlint` on `.github/workflows/build-release.yml`.
- Assert both archive names, both attestation subjects, both checksums, and the shared bundle are uploaded.
- Verify the updater produces separate Niri and Rio metadata with correct URLs and Nix hashes.
- Run `git diff --check`.

### Downstream behavior

- Evaluate a minimal downstream flake using `headless.packages.${system}.rio-bin`.
- Evaluate usage through `pkgs.rio-headless-bin` from the overlay.
- Confirm Rio's terminfo entries are available when the package is installed.

## Performance and accessibility

The downstream package avoids source compilation and remains native code. No Rio runtime behavior is changed. Desktop metadata, icons, manuals, and terminfo are retained so the prebuilt package preserves launcher integration, terminal compatibility, and installed documentation.
