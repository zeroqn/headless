{
  lib,
  fetchurl,
  stdenvNoCC,
}:

let
  releaseTag = "v2026.1017.131201";
  platformAssets = {
    x86_64-linux = {
      name = "Linux-x86_64-ffmpeg.tar.gz";
      hash = "sha256-st5RGcsKuJy2A4rLdSmbIT+XoMedNFVwaK3WOVEfiBU=";
    };
    aarch64-linux = {
      name = "Linux-aarch64-ffmpeg.tar.gz";
      hash = "sha256-+myo9xaSLr1L4iJke/ly7AUK8UVAYYZ4fEO/oDU/Ch0=";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  platformAsset =
    platformAssets.${system} or (throw "No prebuilt FFmpeg asset configured for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "sunshine-prebuilt-ffmpeg";
  version = releaseTag;

  src = fetchurl {
    url = "https://github.com/LizardByte/build-deps/releases/download/${releaseTag}/${platformAsset.name}";
    inherit (platformAsset) hash;
  };

  dontConfigure = true;
  dontBuild = true;
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -R ffmpeg "$out/"

    runHook postInstall
  '';

  meta = {
    description = "Prebuilt LizardByte FFmpeg bundle for Sunshine";
    homepage = "https://github.com/LizardByte/build-deps/releases/tag/${releaseTag}";
    platforms = builtins.attrNames platformAssets;
  };
}
