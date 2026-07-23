# Niri headless and Rio prebuilt Nix flake

This repository builds the `headless` branch of [`zeroqn/niri`](https://github.com/zeroqn/niri/tree/headless) and Rio commit [`d656326`](https://github.com/raphamorim/rio/commit/d656326020ffe5959e221af7a7d1d8d82a6ab2db) once in CI. It publishes complete Nix package outputs on the rolling `main-build` release.

Downstream NixOS systems install the prebuilt packages instead of compiling Niri or Rio locally.

## Package outputs

- `packages.x86_64-linux.default`
- `packages.x86_64-linux.niri`
- `packages.x86_64-linux.niri-headless-bin`
- `packages.x86_64-linux.releaseBuild` builds the Niri source branch used by release CI
- `packages.x86_64-linux.rio-bin`
- `packages.x86_64-linux.rioReleaseBuild` builds the pinned Rio revision used by release CI

The Niri archive includes the executable, session launcher, shell completions, Wayland session metadata, portal configuration, and systemd user units.

The Rio archive includes the executable, terminfo entries, desktop entry, application icon, and manuals.

## Downstream NixOS usage

Use the provided overlay when NixOS configuration or another module expects `pkgs.niri`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    niri-headless.url = "github:zeroqn/headless";
  };

  outputs = { nixpkgs, niri-headless, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        niri-headless.nixosModules.default
        ({ pkgs, ... }: {
          programs.niri.enable = true;
          programs.niri.package = pkgs.niri;

          environment.systemPackages = [
            pkgs.rio-headless-bin
          ];
        })
      ];
    };
  };
}
```

The overlay does not replace nixpkgs `pkgs.rio`; the prebuilt package is exposed as `pkgs.rio-headless-bin`.

Without the overlay:

```nix
environment.systemPackages = [
  niri-headless.packages.${pkgs.system}.default
  niri-headless.packages.${pkgs.system}.rio-bin
];
```

## Release workflow

`.github/workflows/build-release.yml` runs on pushes to `main` and:

1. Builds Niri from `github:zeroqn/niri/headless` without rerunning the upstream test suite.
2. Builds Rio from the pinned `d656326020ffe5959e221af7a7d1d8d82a6ab2db` revision.
3. Archives and checksums both complete Nix package outputs.
4. Generates signed provenance for both archives.
5. Replaces the rolling `main-build` GitHub release with both packages and their verification assets.
6. Updates `release-assets.json` with package-scoped release URLs and Nix hashes.

After publishing assets manually, update the manifest with:

```console
nix run .#update-release-assets
```

The Rio placeholder hash only permits flake evaluation. `packages.x86_64-linux.rio-bin` will not build until CI publishes the first Rio release asset and updates `release-assets.json`.
