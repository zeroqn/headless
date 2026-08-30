{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  releaseAsset,
  runtimeDeps,
}:

stdenvNoCC.mkDerivation {
  pname = "mimalloc-bin";
  inherit (releaseAsset) version;

  src = fetchurl {
    inherit (releaseAsset) url hash;
  };

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    autoPatchelfHook
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
    description = "Prebuilt compact, fast, general-purpose memory allocator";
    homepage = "https://github.com/${releaseAsset.owner}/${releaseAsset.repo}/releases/tag/${releaseAsset.tag}";
    license = lib.licenses.bsd2;
    platforms = [ releaseAsset.system ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
