{
  lib,
  fetchurl,
  stdenvNoCC,
  autoPatchelfHook,
  autoAddDriverRunpath,
  makeWrapper,
  python3,
  releaseAsset,
  runtimeDeps ? [ ],
}:

stdenvNoCC.mkDerivation {
  pname = "sunshine";
  inherit (releaseAsset) version;

  src = fetchurl {
    inherit (releaseAsset) url hash;
  };

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    autoPatchelfHook
    autoAddDriverRunpath
    makeWrapper
    python3
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

    # Release artifacts are produced by a source-build derivation whose
    # compiled-in asset paths point at that build output. The fetched binary is
    # installed into a different store path, so rewrite those fixed-length path
    # prefixes to a relative assets path and run Sunshine from $out below.
    python3 <<'PY'
import os
import re
from pathlib import Path

out = Path(os.environ["out"])
pattern = re.compile(rb"/nix/store/[0-9a-z]{32}-sunshine-[^/\0]+/assets")

for path in (out / "bin").iterdir():
    if not path.is_file() or path.is_symlink():
        continue

    data = path.read_bytes()

    def replacement(match):
        matched = match.group(0)
        return b"assets" + (b"/" * (len(matched) - len(b"assets")))

    patched = pattern.sub(replacement, data)
    if patched != data:
        path.write_bytes(patched)
PY

    # Release artifacts are produced from a Nix source build, so bin/sunshine
    # is already a wrapper with absolute paths to the builder's output. Replace
    # it with a wrapper for this package output instead of preserving stale
    # /nix/store references from the publishing machine.
    rm "$out/bin/sunshine"
    makeWrapper "$out/bin/.sunshine-wrapped" "$out/bin/sunshine" \
      --inherit-argv0 \
      --chdir "$out" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeDeps}"

    service="$out/share/systemd/user/app-dev.lizardbyte.app.Sunshine.service"
    if [ -f "$service" ]; then
      if grep -Eq '^ExecStart=.*/bin/sunshine$' "$service"; then
        sed -i -E "s|^ExecStart=.*/bin/sunshine$|ExecStart=$out/bin/sunshine|" "$service"
      else
        echo "unexpected Sunshine service ExecStart in $service:" >&2
        grep -n '^ExecStart=' "$service" >&2 || true
        exit 1
      fi
    fi

    if [ ! -e "$out/lib/udev/rules.d/60-sunshine.rules" ]; then
      mkdir -p "$out/lib/udev/rules.d"
      cat > "$out/lib/udev/rules.d/60-sunshine.rules" <<'EOF'
# Allows Sunshine to access /dev/uinput
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", GROUP="input", MODE="0660", TAG+="uaccess"

# Allows Sunshine to access /dev/uhid
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"

# Joypads
KERNEL=="hidraw*", ATTRS{name}=="Sunshine PS5 (virtual) pad", GROUP="input", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="input", ATTRS{name}=="Sunshine X-Box One (virtual) pad", GROUP="input", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="input", ATTRS{name}=="Sunshine gamepad (virtual) motion sensors", GROUP="input", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="input", ATTRS{name}=="Sunshine Nintendo (virtual) pad", GROUP="input", MODE="0660", TAG+="uaccess"
EOF
    fi

    if [ ! -e "$out/lib/modules-load.d/60-sunshine.conf" ]; then
      mkdir -p "$out/lib/modules-load.d"
      echo uhid > "$out/lib/modules-load.d/60-sunshine.conf"
    fi

    # Upstream bundles both share/systemd/user and a compatibility symlink at
    # lib/systemd/user -> ../../share/systemd/user. Nix's systemd hook later
    # migrates lib/systemd/user into share/systemd/user, which makes it try to
    # move files onto themselves. Drop only that redundant symlink copy here and
    # keep the canonical share/systemd/user payload intact.
    if [ -L "$out/lib/systemd/user" ] \
      && [ "$(readlink -f "$out/lib/systemd/user")" = "$out/share/systemd/user" ]; then
      chmod u+w "$out/lib/systemd"
      rm "$out/lib/systemd/user"
      rmdir "$out/lib/systemd" 2>/dev/null || true
    fi

    runHook postInstall
  '';

  meta = with lib; {
    description = "Prebuilt Sunshine bundle fetched from GitHub releases";
    homepage = "https://github.com/${releaseAsset.owner}/${releaseAsset.repo}/releases/tag/${releaseAsset.tag}";
    license = licenses.gpl3Only;
    mainProgram = "sunshine";
    platforms = [ releaseAsset.system ];
    sourceProvenance = [ sourceTypes.binaryNativeCode ];
  };
}
