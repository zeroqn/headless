{
  lib,
  fetchurl,
  stdenvNoCC,
}:

let
  releaseTag = "v2026.910.121303";
  platformAssets = {
    x86_64-linux = {
      name = "Linux-x86_64-ffmpeg.tar.gz";
      hash = "sha256-SW0ru2dNAeYDPjG538FcvJ3BSU6IKkUF9qseA/dbOFw=";
    };
    aarch64-linux = {
      name = "Linux-aarch64-ffmpeg.tar.gz";
      hash = "sha256-IfmUCeGroJGR+d8oaI+3+dRPmOZTeKZRMkxjLBmCOqA=";
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
