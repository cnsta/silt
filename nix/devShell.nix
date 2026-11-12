{
  mkShell,
  pkg-config,
  systemdLibs,
  alejandra,
  zig,
}:
mkShell {
  name = "silt-dev-shell";

  nativeBuildInputs = [
    zig
    pkg-config
    alejandra
  ];

  buildInputs = [systemdLibs];

  env.ZIG_GLOBAL_CACHE_DIR = "../.zig-cache/global";
}
