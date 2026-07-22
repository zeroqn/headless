# Niri headless prebuilt Nix flake

This repository builds the `headless` branch of [`zeroqn/niri`](https://github.com/zeroqn/niri/tree/headless) once in CI and publishes the complete Niri package output as `niri-headless-main-x86_64-linux.tar.gz` on the rolling `main-build` release.

Downstream NixOS systems install the prebuilt package by default instead of compiling Niri locally.

## Package outputs

- `packages.x86_64-linux.default`
- `packages.x86_64-linux.niri`
- `packages.x86_64-linux.niri-headless-bin`
- `packages.x86_64-linux.releaseBuild` builds the source branch used by release CI

The archive includes the Niri executable, session launcher, shell completions, Wayland session metadata, portal configuration, and systemd user units.

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
        })
      ];
    };
  };
}
```

Without the overlay:

```nix
environment.systemPackages = [
  niri-headless.packages.${pkgs.system}.default
];
```

## Release workflow

`.github/workflows/build-release.yml` runs on pushes to `main` and:

1. Builds `packages.x86_64-linux.releaseBuild` from `github:zeroqn/niri/headless` without rerunning the upstream test suite.
2. Archives the complete Nix package output.
3. Replaces the rolling `main-build` GitHub release.
4. Updates `release-assets.json` with the release URL and Nix hash.

After publishing an asset manually, update the manifest with:

```console
nix run .#update-release-assets
```

The initial placeholder hash only permits flake evaluation. The default prebuilt package will not build until CI publishes the first release asset and updates `release-assets.json`.
