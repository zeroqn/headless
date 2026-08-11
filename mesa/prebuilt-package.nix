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
  pname = "mesa";
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

    # Extract the build-time store hash from a known JSON file,
    # then rewrite the embedded build-time path to $out everywhere.
    icd="$out/share/vulkan/icd.d/radeon_icd.x86_64.json"
    if [ -f "$icd" ]; then
      old_hash="$(sed -n 's|.*/nix/store/\([^-]*\)-mesa-[^/]*/lib.*|\1|p' "$icd")"
      if [ -n "$old_hash" ]; then
        old_path="/nix/store/$old_hash-mesa-${releaseAsset.version}"
        find "$out" -type f -exec \
          sed -i "s|$old_path|$out|g" {} +
      fi
    fi

    # Fix shebangs on any Python scripts in bin/
    if [ -d "$out/bin" ]; then
      patchShebangs "$out/bin"
    fi

    # Ensure $out/lib is in the RUNPATH
    patchelf --add-rpath "$out/lib" "$out"/lib/*.so 2>/dev/null || true

    runHook postInstall
  '';

  passthru = {
    sourceRevision = releaseAsset.revision or null;
  };

  meta = {
    description = "Prebuilt Mesa graphics library with AMD virtio-gpu DMA-BUF modifier fix";
    homepage = "https://github.com/${releaseAsset.owner}/${releaseAsset.repo}/releases/tag/${releaseAsset.tag}";
    license = lib.licenses.mit;
    platforms = [ releaseAsset.system ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
