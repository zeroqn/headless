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
    rev = "a679b059096bcdd502e2192ce4f6a3c3732fbaae";
    hash = "sha256-yKg+kHy3p8YP7ryyIdj8dhGDblYH0i1GqFgtB4U7fb0=";
    fetchSubmodules = true;
  };
  version = "2026.10.28.vulkan";
in

sunshine.overrideAttrs (old: {
  pname = if cudaSupport then "sunshine-cuda" else "sunshine";

  # Build sunshine from the source in this directory.
  inherit src version;

  patches = (old.patches or [ ]) ++ [
    ./sunshine-mic-common.patch
    ./sunshine-mic.patch
    ./sunshine-multisession-dmabuf.patch
    ./sunshine-teardown-off-http-thread.patch
  ];

  ui = pkgs.buildNpmPackage {
    inherit src version;

    pname = "sunshine-ui";
    npmDepsHash = "sha256-I908PQ4CSiJEbOmi75/0GWnm6iZIUWEsGsmV3XnuN5U=";
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
