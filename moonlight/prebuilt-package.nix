{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  qt6,
  SDL2,
  SDL2_ttf,
  ffmpeg,
  libopus,
  libplacebo,
  openssl,
  alsa-lib,
  libpulseaudio,
  libva,
  libvdpau,
  libxkbcommon,
  wayland,
  libdrm,
  releaseAsset,
}:

stdenvNoCC.mkDerivation {
  pname = "moonlight-qt-bin";
  inherit (releaseAsset) version;

  src = fetchurl {
    inherit (releaseAsset) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    SDL2
    SDL2_ttf
    ffmpeg
    libopus
    libplacebo
    qt6.qtdeclarative
    qt6.qtsvg
    openssl
    alsa-lib
    libpulseaudio
    libva
    libvdpau
    libxkbcommon
    qt6.qtwayland
    wayland
    libdrm
  ];

  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    runHook preUnpack
    mkdir source
    tar --extract --gzip --file "$src" --directory source
    runHook postUnpack
  '';

  sourceRoot = "source";

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a . "$out"/
    chmod -R u+w "$out"
    mv "$out/bin/.moonlight-wrapped" "$out/bin/moonlight"
    runHook postInstall
  '';

  qtWrapperArgs = [
    "--set"
    "QML_DISABLE_DISK_CACHE"
    "1"
  ];

  meta = {
    description = "Play your PC games on almost any device";
    homepage = "https://github.com/${releaseAsset.owner}/${releaseAsset.repo}/releases/tag/${releaseAsset.tag}";
    license = lib.licenses.gpl3Plus;
    platforms = [ releaseAsset.system ];
    mainProgram = "moonlight";
  };
}
