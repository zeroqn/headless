{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  autoAddDriverRunpath,
  releaseAsset,
  runtimeDeps,
}:

stdenvNoCC.mkDerivation {
  pname = "waypipe-bin";
  inherit (releaseAsset) version;

  src = fetchurl {
    inherit (releaseAsset) url hash;
  };

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    autoPatchelfHook
    autoAddDriverRunpath
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
    runHook postInstall
  '';

  meta = {
    description = "Prebuilt network proxy for Wayland clients";
    homepage = "https://github.com/${releaseAsset.owner}/${releaseAsset.repo}/releases/tag/${releaseAsset.tag}";
    license = lib.licenses.mit;
    mainProgram = "waypipe";
    platforms = [ releaseAsset.system ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
