{
  lib,
  stdenv,
  zig,
  systemdLibs,
  pkg-config,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "silt";
  # build.zig.zon's version: bump it there.
  version = lib.pipe ../../../build.zig.zon [
    builtins.readFile
    (builtins.split ''\.version = "([^"]+)"'')
    (builtins.filter builtins.isList)
    builtins.head
    builtins.head
  ];

  src = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../build.zig
      ../../../build.zig.zon
      ../../../src
    ];
  };

  nativeBuildInputs = [
    zig
    pkg-config
  ];

  buildInputs = [systemdLibs];

  zigBuildFlags = ["-Doptimize=ReleaseSafe"];

  doCheck = true;

  zigCheckFlags = finalAttrs.zigBuildFlags;

  meta = {
    description = "Shows what the previous boot left behind: how it ended and its notable journal events";
    license = lib.licenses.bsd0;
    mainProgram = "silt";
    platforms = lib.platforms.linux;
  };
})
