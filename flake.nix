{
  description = "Prebuilt Niri headless release flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    niri-src = {
      url = "github:zeroqn/niri/headless";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      niri-src,
    }:
    let
      releaseMeta = builtins.fromJSON (builtins.readFile ./release-assets.json);
      supportedSystems = builtins.attrNames releaseMeta.assets;

      runtimeDeps =
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

      mkBinaryPackage =
        pkgs: system:
        pkgs.callPackage ./prebuilt-package.nix {
          runtimeDeps = runtimeDeps pkgs;
          releaseAsset = releaseMeta.assets.${system} // {
            inherit system;
            inherit (releaseMeta) owner repo;
            inherit (releaseMeta.release) tag version;
          };
        };

      overlay =
        final: prev:
        let
          system = prev.stdenv.hostPlatform.system;
          hasBinary = builtins.hasAttr system releaseMeta.assets;
        in
        {
          niri-headless-release-build = niri-src.packages.${system}.default.overrideAttrs {
            doCheck = false;
          };
        }
        // prev.lib.optionalAttrs hasBinary {
          niri = mkBinaryPackage prev system;
          niri-headless-bin = final.niri;
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
        };

        apps.update-release-assets = {
          type = "app";
          program = "${updateReleaseAssets}/bin/update-release-assets";
        };

        checks.session-package-metadata =
          assert pkgs.niri.providedSessions == [ "niri" ];
          pkgs.runCommand "niri-session-package-metadata" { } "touch $out";
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
