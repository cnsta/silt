{
  lib,
  newScope,
  zig_0_17,
}:
lib.makeScope newScope (self: {
  zig = zig_0_17;
  silt = self.callPackage ./silt/package.nix {};
})
