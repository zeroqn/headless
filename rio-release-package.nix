{
  lib,
  runCommand,
  rio,
  rioSource,
  scdoc,
}:

runCommand "rio-${rio.version}-release"
  {
    inherit (rio) version;
    nativeBuildInputs = [ scdoc ];
    passthru.sourceRevision = "d656326020ffe5959e221af7a7d1d8d82a6ab2db";
    meta = rio.meta // {
      sourceProvenance = [ lib.sourceTypes.fromSource ];
    };
  }
  ''
    mkdir -p "$out"
    cp -a ${rio}/. "$out"/
    chmod -R u+w "$out"
    cp -a ${rio.terminfo}/. "$out"/
    chmod -R u+w "$out"
    rm -f "$out/nix-support/propagated-user-env-packages"

    mkdir -p "$out/share/man/man1" "$out/share/man/man5"
    scdoc < ${rioSource}/extra/man/rio.1.scd > "$out/share/man/man1/rio.1"
    scdoc < ${rioSource}/extra/man/rio.5.scd > "$out/share/man/man5/rio.5"
    scdoc < ${rioSource}/extra/man/rio-bindings.5.scd > "$out/share/man/man5/rio-bindings.5"
  ''
