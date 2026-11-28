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
    url = "https://github.com/SunshineStream/Sunshine.git";
    rev = "b12662e562b319f942f459404fe766a79748bb6a";
    hash = "sha256-jvr1ULNj/Vi1CDkTNqRCjnZeFJNiVHI8srCtBd7yLv4=";
    fetchSubmodules = true;
  };
  version = "2026.11.27.vulkan";

  # Upstream resolves its C/C++ dependencies through CPM/FetchContent while
  # configuring, which needs the network. Every checkout it asks for is pinned
  # here and handed to cmake as FETCHCONTENT_SOURCE_DIR_<name>, so cmake uses
  # the store path instead of downloading it.
  cpmSources = {
    # The microphone stream flags live in the vendored Moonlight common library.
    moonlight-common-c = pkgs.applyPatches {
      name = "moonlight-common-c-b4ee1ce";
      src = pkgs.fetchgit {
        url = "https://github.com/moonlight-stream/moonlight-common-c.git";
        rev = "b4ee1cea3d19e13c0b37c26585e6b1ee174effcb";
        hash = "sha256-l4UMlfY523DhcuMDOHnYVYLRs2PxPrj7J2fiMveGvXk=";
        fetchSubmodules = true;
      };
      patches = [ ./sunshine-mic-common.patch ];
    };
    simple_web_server = pkgs.fetchgit {
      url = "https://github.com/LizardByte-infrastructure/Simple-Web-Server.git";
      rev = "546895a93a29062bb178367b46c7afb72da9881e";
      hash = "sha256-sIuZUqpK8eiPs1wIlE8hJgtynEoYpLxMaWxQGviifME=";
    };
    libdisplaydevice = pkgs.fetchgit {
      url = "https://github.com/LizardByte/libdisplaydevice.git";
      rev = "a2afc0430d44223c25a2ebc598000f78b338aa52";
      hash = "sha256-uiJ/IoVKcu7RR+p1IPOXBykpLMKoyZ+bMCLH0EHuGjw=";
      # Upstream's submodules (third-party/dockle, third-party/lizardbyte-common)
      # are only wired up when libdisplaydevice is the top-level project
      # (BUILD_DOCS/tests); sunshine consumes it as a FetchContent subproject,
      # where neither is referenced. fetchgit's default here is
      # fetchSubmodules = true, which would make the fixed-output hash cover a
      # recursive checkout this pin does not match.
      fetchSubmodules = false;
    };
    libvirtualhid = pkgs.fetchgit {
      url = "https://github.com/LizardByte/libvirtualhid.git";
      rev = "dd8153df338c6fb399ea4a048fa97b4c536f12a0";
      hash = "sha256-om2LzLvW77msWNF/aSO9m/hkY7DB/DwjwLdopdbjmP0=";
      fetchSubmodules = true;
    };
    glad = pkgs.fetchgit {
      url = "https://github.com/Dav1dde/glad.git";
      rev = "73db193f853e2ee079bf3ca8a64aa2eaf6459043";
      hash = "sha256-aWqqOtNbaWMIKN1KAnXfTbDOgcZ87XaXwVGVgePzLDE=";
    };
    tray = pkgs.fetchgit {
      url = "https://github.com/LizardByte/tray.git";
      rev = "c7b35bb6e3d32b5ce03ce9ef14c25cc178927b2e";
      hash = "sha256-BOIzv/dKYoMqMJoWAPSy98Dmq27V8oudMeviHCTf+DQ=";
      # Same as libdisplaydevice: the dockle/lizardbyte-common submodules are
      # only used when tray is the top-level CMake project.
      fetchSubmodules = false;
    };
    wayland_protocols = pkgs.fetchgit {
      url = "https://github.com/LizardByte-infrastructure/wayland-protocols.git";
      rev = "3eab2dccf4bfdd85c16d312a6c8c8fbc2a6e73a8";
      hash = "sha256-LukbpVpSbwLQ6L6thqSULBn/z4Z6wf8I45/y8/+LU9E=";
    };
    wlr_protocols = pkgs.fetchgit {
      url = "https://github.com/LizardByte-infrastructure/wlr-protocols.git";
      rev = "1106a4a1c57562ddd438c547da4c0d6dc150d624";
      hash = "sha256-xM+VjQ0ngYm3NLhAGKY6qrm2FFngUvpVe5Q0FudgD4g=";
    };
    plasma_wayland_protocols = pkgs.fetchgit {
      url = "https://github.com/KDE/plasma-wayland-protocols.git";
      rev = "c5ac4db818f4a575a6ccfe0065b73ecfaba6e93e";
      hash = "sha256-2Eqt0+24NEZSk3lEtvpkN5RGZ86EKi7/o4qovXk1hTw=";
    };
  };
in

sunshine.overrideAttrs (old: {
  pname = if cudaSupport then "sunshine-cuda" else "sunshine";

  # Build sunshine from the source in this directory.
  inherit src version;

  patches = (old.patches or [ ]) ++ [
    ./sunshine-mic.patch
    ./sunshine-multisession-dmabuf.patch
    ./sunshine-teardown-off-http-thread.patch
    ./sunshine-bounded-launch-prep.patch
    ./sunshine-pairing-session-retry.patch
    ./sunshine-cpm-offline-sources.patch
  ];

  ui = pkgs.buildNpmPackage {
    inherit src version;

    pname = "sunshine-ui";
    npmDepsHash = "sha256-RO9VtNC++Sj/4zaBnd8c2G1ii2Ai1PbpnEl4S9lJUCE=";
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
  ]
  # hand every CPM/FetchContent package the pinned checkout instead of a URL
  ++ map (
    name: pkgs.lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_${pkgs.lib.toUpper name}" "${cpmSources.${name}}"
  ) (builtins.attrNames cpmSources);

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
