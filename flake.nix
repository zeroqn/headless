{
  description = "Prebuilt Niri headless and Rio release flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    niri-src = {
      url = "github:zeroqn/niri/headless";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rio-src = {
      url = "github:raphamorim/rio/d656326020ffe5959e221af7a7d1d8d82a6ab2db";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      niri-src,
      rio-src,
    }:
    let
      releaseMeta = builtins.fromJSON (builtins.readFile ./release-assets.json);
      supportedSystems = builtins.attrNames releaseMeta.packages.niri.assets;

      niriRuntimeDeps =
        pkgs: with pkgs; [
          cairo
          dbus
          libGL
          libdisplay-info
          libinput
          seatd
          libgbm
          libxkbcommon
          pango
          pipewire
          systemd
          wayland
        ];

      rioRuntimeDeps =
        pkgs: with pkgs; [
          gcc-unwrapped
          fontconfig
          libGL
          libxkbcommon
          vulkan-loader
          libx11
          libxcursor
          libxi
          libxrandr
          libxcb
          wayland
        ];

      mkNiriBinaryPackage =
        pkgs: system:
        pkgs.callPackage ./prebuilt-package.nix {
          runtimeDeps = niriRuntimeDeps pkgs;
          releaseAsset = releaseMeta.packages.niri.assets.${system} // {
            inherit system;
            inherit (releaseMeta) owner repo;
            inherit (releaseMeta.release) tag;
            inherit (releaseMeta.packages.niri) version;
          };
        };

      mkRioBinaryPackage =
        pkgs: system:
        pkgs.callPackage ./rio-prebuilt-package.nix {
          runtimeDeps = rioRuntimeDeps pkgs;
          releaseAsset = releaseMeta.packages.rio.assets.${system} // {
            inherit system;
            inherit (releaseMeta) owner repo;
            inherit (releaseMeta.release) tag;
            inherit (releaseMeta.packages.rio) version;
          };
        };

      overlay =
        final: prev:
        let
          system = prev.stdenv.hostPlatform.system;
          hasNiriBinary = builtins.hasAttr system releaseMeta.packages.niri.assets;
          hasRioBinary = builtins.hasAttr system releaseMeta.packages.rio.assets;
        in
        {
          niri-headless-release-build = niri-src.packages.${system}.default.overrideAttrs {
            doCheck = false;
          };
          rio-headless-release-build = prev.callPackage ./rio-release-package.nix {
            rio = rio-src.packages.${system}.default.overrideAttrs {
              doCheck = false;
            };
            rioSource = rio-src;
          };
        }
        // prev.lib.optionalAttrs hasNiriBinary {
          niri = mkNiriBinaryPackage prev system;
          niri-headless-bin = final.niri;
        }
        // prev.lib.optionalAttrs hasRioBinary {
          rio-headless-bin = mkRioBinaryPackage prev system;
        };
    in
    flake-utils.lib.eachSystem supportedSystems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
        updateReleaseAssets = pkgs.writeShellApplication {
          name = "update-release-assets";
          runtimeInputs = [
            pkgs.bash
            pkgs.curl
            pkgs.jq
            pkgs.nix
          ];
          text = ''
            exec bash ${./updater.sh} "$@"
          '';
        };
      in
      {
        packages = {
          default = pkgs.niri;
          niri = pkgs.niri;
          niri-headless-bin = pkgs.niri-headless-bin;
          releaseBuild = pkgs.niri-headless-release-build;
          rio-bin = pkgs.rio-headless-bin;
          rioReleaseBuild = pkgs.rio-headless-release-build;
        };

        apps.update-release-assets = {
          type = "app";
          program = "${updateReleaseAssets}/bin/update-release-assets";
        };

        checks = {
          session-package-metadata =
            assert pkgs.niri.providedSessions == [ "niri" ];
            pkgs.runCommand "niri-session-package-metadata" { } "touch $out";
          rio-package-metadata =
            assert pkgs.rio-headless-bin.meta.mainProgram == "rio";
            assert pkgs.rio != pkgs.rio-headless-bin;
            pkgs.runCommand "rio-package-metadata" { } "touch $out";
        };
        formatter = pkgs.nixfmt;
      }
    )
    // {
      overlays.default = overlay;
      nixosModules.default = { ... }: {
        nixpkgs.overlays = [ self.overlays.default ];
      };
    };
}
