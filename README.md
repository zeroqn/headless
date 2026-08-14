# Headless prebuilt Nix flake

This repository builds and publishes prebuilt Nix package outputs for:

- The `headless` branch of [`zeroqn/niri`](https://github.com/zeroqn/niri/tree/headless).
- Rio commit [`d656326`](https://github.com/raphamorim/rio/commit/d656326020ffe5959e221af7a7d1d8d82a6ab2db).
- Standard and CUDA-enabled Sunshine from the pinned source in `sunshine/source-package.nix`.
- Moonlight Qt commit [`2e13ed9`](https://github.com/moonlight-stream/moonlight-qt/commit/2e13ed9977bc31c73caf8428f08f58d793313ece).
- Waypipe commit [`1ac039b4`](https://gitlab.freedesktop.org/mstoeckl/waypipe/-/commit/1ac039b4d50e2658d284e750c182266cc00efe74).
- Patched Mesa `26.1.5` from the pinned nixpkgs with `patches/mesa-headless-virtio-modifiers.patch` appended (AMD virtio-gpu DMA-BUF modifier fix for radeonsi).

Downstream NixOS systems install the release packages without compiling them locally.

## Package outputs

- `packages.x86_64-linux.default`
- `packages.x86_64-linux.niri`
- `packages.x86_64-linux.niri-headless-bin`
- `packages.x86_64-linux.releaseBuild`
- `packages.x86_64-linux.rio-bin`
- `packages.x86_64-linux.rioReleaseBuild`
- `packages.x86_64-linux.sunshine`
- `packages.x86_64-linux.sunshine-bin`
- `packages.x86_64-linux.sunshine-bin-cuda`
- `packages.x86_64-linux.sunshineReleaseBuild`
- `packages.x86_64-linux.sunshineReleaseBuildCuda`
- `packages.x86_64-linux.moonlight-qt`
- `packages.x86_64-linux.moonlight-qt-bin`
- `packages.x86_64-linux.moonlightReleaseBuild`
- `packages.x86_64-linux.waypipe`
- `packages.x86_64-linux.waypipe-bin`
- `packages.x86_64-linux.waypipeReleaseBuild`
- `packages.x86_64-linux.mesa`
- `packages.x86_64-linux.mesa-headless-bin`
- `packages.x86_64-linux.mesaReleaseBuild`

The default package remains Niri. `sunshine` and `sunshine-bin` are the standard Sunshine package; CUDA is only enabled by selecting `sunshine-bin-cuda` explicitly. `mesa` and `mesa-headless-bin` are the patched prebuilt Mesa; `mesaReleaseBuild` is the pinned source build used by release CI. The initial Mesa prebuilt supports `x86_64-linux` only, and the nixpkgs Mesa auxiliary outputs (`opencl`, `spirv2dxil`, `cross_tools`, `debug`) remain supplied by nixpkgs via passthru.

## Downstream NixOS usage

Import the provided module when NixOS configuration or another module should use the prebuilt `pkgs.niri`, `pkgs.sunshine`, `pkgs.moonlight-qt`, and `pkgs.waypipe` packages:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    headless.url = "github:zeroqn/headless";
  };

  outputs = { nixpkgs, headless, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        headless.nixosModules.default
        ({ pkgs, ... }: {
          programs.niri.enable = true;
          programs.niri.package = pkgs.niri;

          services.sunshine = {
            enable = true;
            package = pkgs.sunshine;
          };

          environment.systemPackages = [
            pkgs.rio-headless-bin
            pkgs.moonlight-qt
            pkgs.waypipe
          ];

          hardware.graphics.enable = true;
        })
      ];
    };
  };
}
```

The overlay does not replace nixpkgs `pkgs.rio`; Rio is exposed as `pkgs.rio-headless-bin`. The overlay replaces nixpkgs `pkgs.waypipe` with the prebuilt package and also exposes the same package as `pkgs.waypipe-bin`. The overlay replaces nixpkgs `pkgs.mesa` with the patched prebuilt package and exposes the same package as `pkgs.mesa-headless-bin`, so `hardware.graphics.package` (which defaults to `pkgs.mesa`) resolves to the patched Mesa on AMD virtio-gpu native-context guests. Packages that build against `pkgs.mesa`'s non-`out` outputs should use `pkgs.mesa-headless-release-build` instead.

For a CUDA-enabled Sunshine service, allow unfree packages in the downstream Nixpkgs configuration and select the CUDA package explicitly:

```nix
{
  nixpkgs.config.allowUnfree = true;
  services.sunshine.package = pkgs.sunshine-bin-cuda;
}
```

For DRM/KMS capture that requires Sunshine's privileged wrapper:

```nix
services.sunshine = {
  enable = true;
  capSysAdmin = true;
};
```

The Headless module preserves `cap_sys_admin,cap_sys_nice+p` for that opt-in wrapper.

Without the overlay or module:

```nix
environment.systemPackages = [
  headless.packages.${pkgs.system}.default
  headless.packages.${pkgs.system}.rio-bin
  headless.packages.${pkgs.system}.sunshine-bin
  headless.packages.${pkgs.system}.moonlight-qt
  headless.packages.${pkgs.system}.waypipe
];

hardware.graphics.package = headless.packages.${pkgs.system}.mesa;
```

## Migrating from the standalone Sunshine flake

Replace:

```nix
sunshine-prebuilt.url = "github:zeroqn/sunshine";
```

with:

```nix
headless.url = "github:zeroqn/headless";
```

Then replace standalone package references with:

```nix
headless.packages.${pkgs.system}.sunshine-bin
headless.packages.${pkgs.system}.sunshine-bin-cuda
```

The standalone Sunshine repository is not modified by this repository change. Retiring or archiving it is a separate operation after the Headless release publishes and verifies both Sunshine variants.

## Migrating from the standalone Moonlight Qt flake

Replace:

```nix
moonlight-qt.url = "github:zeroqn/moonlight-qt";
```

with the shared Headless input:

```nix
headless.url = "github:zeroqn/headless";
```

Replace `moonlight-qt.nixosModules.default` with `headless.nixosModules.default`.

Existing overlay-based package references remain `pkgs.moonlight-qt`. Without the overlay, use:

```nix
headless.packages.${pkgs.system}.moonlight-qt
```

Source-build consumers replace the standalone `releaseBuild` output with:

```nix
headless.packages.${pkgs.system}.moonlightReleaseBuild
```

The standalone Moonlight Qt repository is not modified by this repository change. Retiring or archiving it is a separate operation after the Headless Moonlight release asset is published and verified.

## Release workflow

`.github/workflows/build-release.yml` runs on pushes to `main` and:

1. Builds Niri and Rio in one package group.
2. Builds standard and CUDA Sunshine in a separate package group.
3. Builds Moonlight Qt in an independent package group.
4. Builds Waypipe in an independent package group.
5. Builds patched Mesa in an independent package group.
6. Packages, checksums, and attests each successful group.
7. Serializes release publication without deleting the rolling `main-build` release.
8. Overwrites only assets owned by successful groups, leaving failed groups' existing assets intact.
9. Updates only the published groups in `release-assets.json`.
10. Commits the metadata and pushes it with a fetch-and-rebase retry (`push-release-metadata.sh`), so concurrent workflow runs (e.g. the weekly Mesa schedule) integrate instead of failing on a stale `main`.

After publishing assets manually, update all package metadata with:

```console
nix run .#update-release-assets
```

Refresh only one publication group with:

```console
PUBLISH_GROUPS=sunshine nix run .#update-release-assets
PUBLISH_GROUPS=niri-rio nix run .#update-release-assets
PUBLISH_GROUPS=moonlight nix run .#update-release-assets
PUBLISH_GROUPS=waypipe nix run .#update-release-assets
PUBLISH_GROUPS=mesa nix run .#update-release-assets
```
