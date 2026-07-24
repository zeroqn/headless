# Headless prebuilt Nix flake

This repository builds and publishes prebuilt Nix package outputs for:

- The `headless` branch of [`zeroqn/niri`](https://github.com/zeroqn/niri/tree/headless).
- Rio commit [`d656326`](https://github.com/raphamorim/rio/commit/d656326020ffe5959e221af7a7d1d8d82a6ab2db).
- Standard and CUDA-enabled Sunshine from the pinned source in `sunshine/source-package.nix`.

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

The default package remains Niri. `sunshine` and `sunshine-bin` are the standard Sunshine package; CUDA is only enabled by selecting `sunshine-bin-cuda` explicitly.

## Downstream NixOS usage

Import the provided module when NixOS configuration or another module should use the prebuilt `pkgs.niri` and `pkgs.sunshine` packages:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
          ];
        })
      ];
    };
  };
}
```

The overlay does not replace nixpkgs `pkgs.rio`; Rio is exposed as `pkgs.rio-headless-bin`.

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
];
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

## Release workflow

`.github/workflows/build-release.yml` runs on pushes to `main` and:

1. Builds Niri and Rio in one package group.
2. Builds standard and CUDA Sunshine in a separate package group.
3. Packages, checksums, and attests each successful group.
4. Serializes release publication without deleting the rolling `main-build` release.
5. Overwrites only assets owned by successful groups, leaving failed groups' existing assets intact.
6. Updates only the published groups in `release-assets.json`.

After publishing assets manually, update all package metadata with:

```console
nix run .#update-release-assets
```

Refresh only one publication group with:

```console
PUBLISH_GROUPS=sunshine nix run .#update-release-assets
PUBLISH_GROUPS=niri-rio nix run .#update-release-assets
```
