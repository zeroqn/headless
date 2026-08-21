{
  pkgs,
  cudaSupport ? false,
  ...
}:

let
  buildDeps = pkgs.callPackage ./build-deps.nix { };
  sunshine = pkgs.sunshine.override {
    inherit cudaSupport;
    cudaPackages = pkgs.cudaPackages;
  };
  coreutilsForService = pkgs.coreutils.overrideAttrs (_: {
    # Local Nix rebuilds of coreutils can fail an unrelated cp test under this
    # container filesystem. We only need a stable sleep path in the generated
    # user service, so skip coreutils' self-tests for this narrowly-scoped use.
    doCheck = false;
    doInstallCheck = false;
  });
  pythonForGlad = pkgs.python3.withPackages (ps: [
    ps.jinja2
    ps.setuptools
  ]);
  src = pkgs.fetchgit {
    url = "https://github.com/LizardByte/Sunshine.git";
    rev = "3dfbfe0906cf5970f84b96a1451451eaa2ab1fab";
    hash = "sha256-tMPjj7mjwiY7P2SO+dIczjJLlf24bASflpUBGfk2plU=";
    fetchSubmodules = true;
  };
  version = "2026.08.21.vulkan";
  boostVersion = pkgs.boost.version;
in

sunshine.overrideAttrs (old: {
  pname = if cudaSupport then "sunshine-cuda" else "sunshine";

  # Build sunshine from the source in this directory.
  inherit src version;

  patches = (old.patches or [ ]) ++ [
    ./sunshine-pr-5427.patch
  ];

  ui = pkgs.buildNpmPackage {
    inherit src version;

    pname = "sunshine-ui";
    npmDepsHash = "sha256-W4MZQQO7BJQNStROjq/iSRAuUcNO9y66C6aFep28Qpk=";
    nodejs = pkgs.nodejs_24;

    # keep npm dependency hashing tied to this repo's checked-in lockfile
    postPatch = ''
      cp ${./package-lock.json} ./package-lock.json
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp -a . "$out"/

      runHook postInstall
    '';
  };

  postPatch = ''
        substituteInPlace cmake/targets/common.cmake \
          --replace-fail 'find_program(NPM npm REQUIRED)' ""

        sed -i -E 's|set\(BOOST_VERSION "[^"]+"\)|set(BOOST_VERSION "${boostVersion}")|' \
          cmake/dependencies/Boost_Sunshine.cmake
        grep -Fq 'set(BOOST_VERSION "${boostVersion}")' \
          cmake/dependencies/Boost_Sunshine.cmake
        echo 'set(FETCH_CONTENT_BOOST_USED TRUE)' >> cmake/dependencies/Boost_Sunshine.cmake

        substituteInPlace cmake/packaging/linux.cmake \
          --replace-fail 'find_package(Systemd)' "" \
          --replace-fail 'find_package(Udev)' ""

        substituteInPlace packaging/linux/dev.lizardbyte.app.Sunshine.desktop \
          --subst-var-by PROJECT_NAME 'Sunshine' \
          --subst-var-by PROJECT_DESCRIPTION 'Self-hosted game stream host for Moonlight' \
          --subst-var-by SUNSHINE_DESKTOP_ICON 'sunshine' \
          --subst-var-by CMAKE_INSTALL_FULL_DATAROOTDIR "$out/share" \
          --replace-fail 'Exec=/usr/bin/env systemctl start --u app-@PROJECT_FQDN@' 'Exec=sunshine'

        substituteInPlace packaging/linux/app-dev.lizardbyte.app.Sunshine.service.in \
          --replace-fail '/bin/sleep' '${pkgs.lib.getExe' coreutilsForService "sleep"}'

        python <<'PY'
    from pathlib import Path

    path = Path('src/nvenc/nvenc_base.cpp')
    text = path.read_text()
    text = text.replace(
        '#if NVENCAPI_VERSION != MAKE_NVENC_VER(13U, 0U)\n  #error Check and update NVENC code for backwards compatibility!\n#endif',
        '#if NVENCAPI_VERSION < MAKE_NVENC_VER(12U, 0U) || NVENCAPI_VERSION > MAKE_NVENC_VER(13U, 0U)\n  #error Check and update NVENC code for backwards compatibility!\n#endif'
    )
    hevc_10bit = '          if (buffer_is_10bit()) {\n            format_config.inputBitDepth = NV_ENC_BIT_DEPTH_10;\n            format_config.outputBitDepth = NV_ENC_BIT_DEPTH_10;\n          }'
    text = text.replace(
        hevc_10bit,
        '          if (buffer_is_10bit()) {\n#if NVENCAPI_MAJOR_VERSION >= 13\n            format_config.inputBitDepth = NV_ENC_BIT_DEPTH_10;\n            format_config.outputBitDepth = NV_ENC_BIT_DEPTH_10;\n#else\n            format_config.pixelBitDepthMinus8 = 2;\n#endif\n          }',
        1
    )
    text = text.replace(
        hevc_10bit,
        '          if (buffer_is_10bit()) {\n#if NVENCAPI_MAJOR_VERSION >= 13\n            format_config.inputBitDepth = NV_ENC_BIT_DEPTH_10;\n            format_config.outputBitDepth = NV_ENC_BIT_DEPTH_10;\n#else\n            format_config.inputPixelBitDepthMinus8 = 2;\n            format_config.pixelBitDepthMinus8 = 2;\n#endif\n          }',
        1
    )
    path.write_text(text)
    PY
  '';

  nativeBuildInputs = [
    pythonForGlad
    pkgs.glslang
    pkgs.qt6.wrapQtAppsHook
  ]
  ++ old.nativeBuildInputs;

  buildInputs = old.buildInputs ++ [
    pkgs.pipewire
    pkgs.vulkan-headers
    pkgs.vulkan-loader
    pkgs.qt6.qtbase
    pkgs.qt6.qtsvg
  ];

  cmakeFlags = old.cmakeFlags ++ [
    (pkgs.lib.cmakeBool "SUNSHINE_ENABLE_VULKAN" true)
    (pkgs.lib.cmakeBool "GLAD_SKIP_PIP_INSTALL" true)
    (pkgs.lib.cmakeFeature "Python_EXECUTABLE" "${pythonForGlad}/bin/python3")
    (pkgs.lib.cmakeFeature "FFMPEG_PREPARED_BINARIES" "${buildDeps}/ffmpeg")
    (pkgs.lib.cmakeFeature "SUNSHINE_EXECUTABLE_PATH" "${placeholder "out"}/bin/sunshine")
    (pkgs.lib.cmakeFeature "SUNSHINE_ASSETS_DIR_DEF" "assets")
    (pkgs.lib.cmakeBool "UDEV_FOUND" true)
    (pkgs.lib.cmakeFeature "UDEV_RULES_INSTALL_DIR" "lib/udev/rules.d")
    (pkgs.lib.cmakeBool "SYSTEMD_FOUND" true)
    (pkgs.lib.cmakeFeature "SYSTEMD_USER_UNIT_INSTALL_DIR" "lib/systemd/user")
    (pkgs.lib.cmakeFeature "SYSTEMD_MODULES_LOAD_DIR" "lib/modules-load.d")
  ];

  qtWrapperArgs = [
    "--chdir"
    (placeholder "out")
    "--set"
    "LD_LIBRARY_PATH"
    (pkgs.lib.makeLibraryPath (
      [ pkgs.vulkan-loader ] ++ pkgs.lib.optionals cudaSupport [ pkgs.cudaPackages.cuda_cudart ]
    ))
  ];

  enableParallelBuilding = false;

})
