{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    genAttrs
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.silt;

  siltPkgs = pkgs.callPackage ./pkgs {};
in {
  options.programs.silt = {
    enable = mkEnableOption "silt, a viewer for what the previous boot left in the journal";

    package = mkOption {
      type = types.package;
      default = siltPkgs.silt;
      defaultText = lib.literalMD "`silt` from this flake, built with the system's nixpkgs";
      description = "The silt package to install.";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["alice"];
      description = ''
        Users to add to the `systemd-journal` group. silt only sees the system
        journal (kernel messages, failed units, how the boot ended) when run by
        root or by a member of `systemd-journal` or `wheel`; anyone else gets
        just their own user journal. Leave it empty if your users are in
        `wheel` already.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    users.users = genAttrs cfg.users (_: {
      extraGroups = ["systemd-journal"];
    });
  };
}
