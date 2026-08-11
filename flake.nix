{
  description = "Prebuilt Niri headless, Rio, Sunshine, Moonlight Qt, and Waypipe release flake";

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
          libdisplay-info_0_3
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

      sunshineRuntimeDeps =
        pkgs: cudaSupport:
        with pkgs;
        [
          at-spi2-core
          avahi
          boost
          cairo
          curl
          gdk-pixbuf
          glib
          gtk3
          harfbuzz
          libappindicator-gtk3
          libcap
          libdbusmenu-gtk3
          libdrm
          libevdev
          libglvnd
          libgbm
          libICE
          libnotify
          libopus
          libpulseaudio
          libSM
          libva
          libvdpau
          miniupnpc
          numactl
          openssl
          pango
          pipewire
          qt6.qtbase
          qt6.qtsvg
          vulkan-loader
          wayland
          libx11
          libxcb
          libxext
          libxfixes
          libxi
          libxkbcommon
          libxrandr
          libxtst
          zlib
        ]
        ++ lib.optionals cudaSupport [ cudaPackages.cuda_cudart ];

      moonlightRevision = "1d1fe1aac39dd414ed825fe834b84a0e4eea8338";
      waypipeRevision = "1ac039b4d50e2658d284e750c182266cc00efe74";
      waypipeVersion = "0.11.0-unstable-2026-06-17";

      waypipeRuntimeDeps =
        pkgs: with pkgs; [
          ffmpeg
          libgbm
          lz4
          vulkan-loader
          zstd
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

      mkSunshineBinaryPackage =
        pkgs: system: cudaSupport:
        let
          packageName = if cudaSupport then "sunshine-cuda" else "sunshine";
        in
        pkgs.callPackage ./sunshine/prebuilt-package.nix {
          runtimeDeps = sunshineRuntimeDeps pkgs cudaSupport;
          releaseAsset = releaseMeta.packages.${packageName}.assets.${system} // {
            inherit system;
            inherit (releaseMeta) owner repo;
            inherit (releaseMeta.release) tag;
            inherit (releaseMeta.packages.${packageName}) version;
          };
        };

      mkSunshineSourceBuild =
        pkgs: cudaSupport:
        pkgs.callPackage ./sunshine/source-package.nix {
          inherit pkgs cudaSupport;
        };

      mkMoonlightBinaryPackage =
        pkgs: system:
        pkgs.callPackage ./moonlight/prebuilt-package.nix {
          releaseAsset = releaseMeta.packages.moonlight.assets.${system} // {
            inherit system;
            inherit (releaseMeta) owner repo;
            inherit (releaseMeta.release) tag;
            inherit (releaseMeta.packages.moonlight) version;
          };
        };

      mkMoonlightSourceBuild =
        pkgs:
        pkgs.moonlight-qt.overrideAttrs {
          version = builtins.substring 0 7 moonlightRevision;
          src = pkgs.fetchFromGitHub {
            owner = "moonlight-stream";
            repo = "moonlight-qt";
            rev = moonlightRevision;
            hash = "sha256-0cWR9uLQIa1eQOuQMTxbzWg7lFmqQ1hgle/Z+vCC/9k=";
            fetchSubmodules = true;
          };
          patches = [ ];
        };

      mkWaypipeBinaryPackage =
        pkgs: system:
        pkgs.callPackage ./waypipe/prebuilt-package.nix {
          runtimeDeps = waypipeRuntimeDeps pkgs;
          releaseAsset = releaseMeta.packages.waypipe.assets.${system} // {
            inherit system;
            inherit (releaseMeta) owner repo;
            inherit (releaseMeta.release) tag;
            inherit (releaseMeta.packages.waypipe) version;
          };
        };

      mkWaypipeSourceBuild =
        pkgs:
        pkgs.waypipe.overrideAttrs (finalAttrs: {
          version = waypipeVersion;
          src = pkgs.fetchFromGitLab {
            domain = "gitlab.freedesktop.org";
            owner = "mstoeckl";
            repo = "waypipe";
            rev = waypipeRevision;
            hash = "sha256-rSTphq/ZJItyp3DTcZyHxD8LvdA0FKCCaA0lw0TXQeA=";
          };
          cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
            inherit (finalAttrs) pname version src;
            hash = "sha256-IUvXHLxrhc2Au57wsE53Q+NL1cZzFcaRG3HDV8s3xWw=";
          };
          dontGzipMan = true;
          passthru = (finalAttrs.passthru or { }) // {
            sourceRevision = waypipeRevision;
          };
        });

      overlay =
        final: prev:
        let
          system = prev.stdenv.hostPlatform.system;
          hasNiriBinary = builtins.hasAttr system releaseMeta.packages.niri.assets;
          hasRioBinary = builtins.hasAttr system releaseMeta.packages.rio.assets;
          hasSunshineBinary = builtins.hasAttr system releaseMeta.packages.sunshine.assets;
          hasSunshineCudaBinary = builtins.hasAttr system releaseMeta.packages."sunshine-cuda".assets;
          hasMoonlightBinary = builtins.hasAttr system releaseMeta.packages.moonlight.assets;
          hasWaypipeBinary = builtins.hasAttr system releaseMeta.packages.waypipe.assets;
        in
        {
          niri-headless-release-build = niri-src.packages.${system}.default.overrideAttrs {
            doCheck = false;
          };
          rio-headless-release-build = prev.callPackage ./rio-release-package.nix {
            rio = rio-src.packages.${system}.default.overrideAttrs (oldAttrs: {
              doCheck = false;
              patches = (oldAttrs.patches or [ ]) ++ [
                ./patches/rio-pr-1626.patch
              ];
            });
            rioSource = rio-src;
          };
          sunshine-headless-release-build = mkSunshineSourceBuild prev false;
          sunshine-headless-release-build-cuda = mkSunshineSourceBuild prev true;
          moonlight-headless-release-build = mkMoonlightSourceBuild prev;
          waypipe-headless-release-build = mkWaypipeSourceBuild prev;
        }
        // prev.lib.optionalAttrs hasNiriBinary {
          niri = mkNiriBinaryPackage prev system;
          niri-headless-bin = final.niri;
        }
        // prev.lib.optionalAttrs hasRioBinary {
          rio-headless-bin = mkRioBinaryPackage prev system;
        }
        // prev.lib.optionalAttrs hasSunshineBinary {
          sunshine = mkSunshineBinaryPackage prev system false;
          sunshine-bin = final.sunshine;
        }
        // prev.lib.optionalAttrs hasSunshineCudaBinary {
          sunshine-bin-cuda = mkSunshineBinaryPackage prev system true;
        }
        // prev.lib.optionalAttrs hasMoonlightBinary {
          moonlight-qt = mkMoonlightBinaryPackage prev system;
          moonlight-qt-bin = final.moonlight-qt;
        }
        // prev.lib.optionalAttrs hasWaypipeBinary {
          waypipe = mkWaypipeBinaryPackage prev system;
          waypipe-bin = final.waypipe;
        };
    in
    flake-utils.lib.eachSystem supportedSystems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
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

          sunshine = pkgs.sunshine;
          sunshine-bin = pkgs.sunshine-bin;
          sunshine-bin-cuda = pkgs.sunshine-bin-cuda;
          sunshineReleaseBuild = pkgs.sunshine-headless-release-build;
          sunshineReleaseBuildCuda = pkgs.sunshine-headless-release-build-cuda;

          moonlight-qt = pkgs.moonlight-qt;
          moonlight-qt-bin = pkgs.moonlight-qt-bin;
          moonlightReleaseBuild = pkgs.moonlight-headless-release-build;

          waypipe = pkgs.waypipe;
          waypipe-bin = pkgs.waypipe-bin;
          waypipeReleaseBuild = pkgs.waypipe-headless-release-build;
        };

        apps.update-release-assets = {
          type = "app";
          program = "${updateReleaseAssets}/bin/update-release-assets";
        };

        checks = {
          session-package-metadata =
            assert pkgs.niri.providedSessions == [ "niri" ];
            pkgs.runCommand "niri-session-package-metadata" { } "touch $out";
          niri-runtime-dep-mirror =
            let
              rawPkgs = import nixpkgs { inherit system; };
              sourceLibdi = builtins.head (
                builtins.filter (d: builtins.match ".*libdisplay-info.*" d.name != null) (
                  rawPkgs.niri.buildInputs or [ ]
                )
              );
              prebuiltLibdi = builtins.head (
                builtins.filter (d: builtins.match ".*libdisplay-info.*" d.name != null) (
                  pkgs.niri-headless-bin.passthru.runtimeDeps or [ ]
                )
              );
            in
            if prebuiltLibdi.name != sourceLibdi.name then
              throw "niri prebuilt runtimeDeps libdisplay-info ${prebuiltLibdi.name} does not mirror the source build's ${sourceLibdi.name}"
            else
              pkgs.runCommand "niri-runtime-dep-mirror" { } "touch $out";
          rio-package-metadata =
            assert pkgs.rio-headless-bin.meta.mainProgram == "rio";
            assert pkgs.rio != pkgs.rio-headless-bin;
            assert
              pkgs.rio-headless-release-build.passthru.sourceRevision
              == "d656326020ffe5959e221af7a7d1d8d82a6ab2db";
            pkgs.runCommand "rio-package-metadata" { } "touch $out";
          sunshine-package-metadata =
            assert pkgs.sunshine == pkgs.sunshine-bin;
            assert pkgs.sunshine != pkgs.sunshine-bin-cuda;
            assert pkgs.sunshine.meta.mainProgram == "sunshine";
            pkgs.runCommand "sunshine-package-metadata" { } "touch $out";
          moonlight-package-metadata =
            assert pkgs.moonlight-qt == pkgs.moonlight-qt-bin;
            assert pkgs.moonlight-qt.meta.mainProgram == "moonlight";
            pkgs.runCommand "moonlight-package-metadata" { } "touch $out";
          waypipe-package-metadata =
            assert pkgs.waypipe == pkgs.waypipe-bin;
            assert pkgs.waypipe.meta.mainProgram == "waypipe";
            assert pkgs.waypipe-headless-release-build.dontGzipMan;
            assert
              pkgs.waypipe-headless-release-build.passthru.sourceRevision
              == "1ac039b4d50e2658d284e750c182266cc00efe74";
            pkgs.runCommand "waypipe-package-metadata" { } "touch $out";
        };
        formatter = pkgs.nixfmt;
      }
    )
    // {
      overlays.default = overlay;
      nixosModules.default =
        {
          config,
          lib,
          ...
        }:
        {
          nixpkgs.overlays = [ self.overlays.default ];
          security.wrappers.sunshine.capabilities = lib.mkIf (
            config.services.sunshine.enable && config.services.sunshine.capSysAdmin
          ) (lib.mkForce "cap_sys_admin,cap_sys_nice+p");
        };
    };
}
