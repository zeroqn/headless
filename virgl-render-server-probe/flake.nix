{
  description = "Host-side virgl venus / RENDER_SERVER probe (nested libkrun L2 Vulkan)";

  inputs = {
    # Pin to the exact nixpkgs revision the repo's flake.lock uses so the probe
    # resolves against the same (already-in-the-store) nixpkgs the repo builds
    # with, and so the first `nix build`/`nix run` needs no network.
    nixpkgs.url = "github:NixOS/nixpkgs/d3498f786f97ac0bded21b34bae0bf3809b45aa3";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkProbe =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          vr = pkgs.virglrenderer;
        in
        pkgs.stdenv.mkDerivation {
          pname = "virgl-render-server-probe";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = [ vr pkgs.vulkan-loader ];

          buildPhase = ''
            runHook preBuild
            # Use `vr` directly rather than pkg-config: this virglrenderer's .pc
            # reports includedir=<...>/include/virgl, which does not match the
            # probe's `#include <virgl/virglrenderer.h>` (that needs -I<...>/include).
            # `-I${vr}/include -L${vr}/lib` is exactly how the repo builds against it.
            $CC -O2 -Wall -Wno-deprecated-declarations probe.c \
              -I${vr}/include -L${vr}/lib -lvirglrenderer -ldl -lpthread \
              -Wl,-rpath,${vr}/lib \
              -o virgl-probe-bin
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -m 0755 virgl-probe-bin "$out/bin/virgl-probe-bin"
            # makeWrapper forwards "$@" and lets us bake in RENDER_SERVER_EXEC_PATH
            # plus the library paths (virglrenderer for the render server, and the
            # Vulkan loader so virglrenderer can dlsym libvulkan.so.1 at runtime).
            makeWrapper "$out/bin/virgl-probe-bin" "$out/bin/virgl-probe" \
              --set RENDER_SERVER_EXEC_PATH ${vr}/libexec/virgl_render_server \
              --prefix LD_LIBRARY_PATH : ${vr}/lib:${pkgs.vulkan-loader}/lib \
              --prefix PATH : ${vr}/libexec:${vr}/bin
            runHook postInstall
          '';

          meta = {
            description = "Host-side virgl venus/RENDER_SERVER probe for nested L2 Vulkan";
            mainProgram = "virgl-probe";
          };
        };
    in
    {
      packages = forAllSystems (system: {
        virgl-probe = mkProbe system;
        default = mkProbe system;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.virgl-probe}/bin/virgl-probe";
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          vr = pkgs.virglrenderer;
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.gcc
              vr
              pkgs.vulkan-loader
              pkgs.vulkan-tools
            ];
            shellHook = ''
              export VIRGLRENDERER=${vr}
              export VK_LIBDIR=${pkgs.vulkan-loader}/lib
              export RENDER_SERVER_EXEC_PATH=${vr}/libexec/virgl_render_server
              export LD_LIBRARY_PATH=${vr}/lib:${pkgs.vulkan-loader}/lib:"$LD_LIBRARY_PATH"
              echo "virgl venus/RENDER_SERVER probe dev shell"
              echo "  RENDER_SERVER_EXEC_PATH=$RENDER_SERVER_EXEC_PATH"
              echo "  Run: bash run-probe.sh venus-rs   or   nix run . -- venus-rs"
              echo "  (if the venus capset stays absent, set VK_DRIVER_FILES to your radv ICD)"
            '';
          };
        }
      );
    };
}
