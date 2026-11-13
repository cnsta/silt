{
  description = "silt: what the previous boot left behind";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";

    systems.url = "github:nix-systems/default";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    ...
  }: let
    inherit (nixpkgs) lib legacyPackages;
    platforms = lib.filter (lib.hasSuffix "-linux") (lib.attrNames zig.packages);
    forAllPlatforms = f: lib.genAttrs platforms (s: f legacyPackages.${s});
  in {
    devShells = forAllPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = zig.packages.${pkgs.stdenv.hostPlatform.system}."0.17.1";
      };
    });

    packages = forAllPlatforms (pkgs: let
      scope = pkgs.callPackage ./nix/pkgs {};
    in {
      inherit (scope) silt;
      default = scope.silt;
    });

    overlays.default = final: _prev: let
      scope = final.callPackage ./nix/pkgs {};
    in {
      inherit (scope) silt;
    };

    formatter = forAllPlatforms (pkgs: pkgs.alejandra);

    nixosModules.silt = ./nix/nixosModule.nix;
    nixosModules.default = self.nixosModules.silt;
  };
}
