{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  autoAddDriverRunpath,
  makeWrapper,
  bash,
  coreutils,
  dbus,
  procps,
  systemd,
  releaseAsset,
  runtimeDeps,
}:

stdenvNoCC.mkDerivation {
  pname = "niri-headless-bin";
  inherit (releaseAsset) version;

  src = fetchurl {
    inherit (releaseAsset) url hash;
  };

  dontConfigure = true;
  dontBuild = true;
  dontMoveSystemdUserUnits = true;

  nativeBuildInputs = [
    autoPatchelfHook
    autoAddDriverRunpath
    makeWrapper
  ];

  buildInputs = map lib.getLib runtimeDeps;
  runtimeDependencies = map lib.getLib runtimeDeps;

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

    patchShebangs "$out/bin/niri-session"

    service="$out/lib/systemd/user/niri.service"
    if [ -f "$service" ]; then
      if grep -Eq '^ExecStart=/nix/store/[^/]+-niri-[^/]+/bin/niri --session$' "$service"; then
        sed -i -E \
          "s|^ExecStart=/nix/store/[^/]+-niri-[^/]+/bin/niri --session$|ExecStart=$out/bin/niri --session|" \
          "$service"
      elif ! grep -Fqx "ExecStart=$out/bin/niri --session" "$service"; then
        echo "unexpected niri.service ExecStart:" >&2
        grep -n '^ExecStart=' "$service" >&2 || true
        exit 1
      fi
    fi

    wrapProgram "$out/bin/niri-session" \
      --prefix PATH : "$out/bin:${
        lib.makeBinPath [
          bash
          coreutils
          dbus
          procps
          systemd
        ]
      }"

    runHook postInstall
  '';

  passthru.providedSessions = [ "niri" ];

  meta = {
    description = "Prebuilt Niri scrollable-tiling Wayland compositor with headless support";
    homepage = "https://github.com/${releaseAsset.owner}/${releaseAsset.repo}/releases/tag/${releaseAsset.tag}";
    license = lib.licenses.gpl3Only;
    mainProgram = "niri";
    platforms = [ releaseAsset.system ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
