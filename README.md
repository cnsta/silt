# silt

What the river leaves behind after the flood: silt opens the previous boot's
journal, says how that boot ended, and shows only what's worth reading.

- **How it ended**: powered off, rebooted, hung while shutting down, never woke
  from sleep, or ended abruptly (no "Journal stopped": a crash, hard hang or
  power loss), with the gap until the next boot.
- **Notable events**: kernel oops/BUG/panic/lockups, hardware errors (MCE, I/O),
  OOM kills, coredumps and segfaults, GPU timeouts and resets, failed units, and
  errors. Repeats are collapsed (`×340`) and a short list of routine complaints
  is hidden (`-noise` or `n` shows them).
- **New in this boot**: an event is marked `+` if nothing like it was logged in
  the 5 boots before (`-history <n>`, 0 turns it off), so the errors every boot
  has don't bury the one that matters. `+` in the TUI or `-plain -new` lists
  only those.
- **Last 60s**: everything logged right before the end.
- **pstore**: panics that never reached the journal, if readable.

```
silt            # the previous boot, in a TUI
silt -b -3      # boot offsets are journalctl's
silt -list      # every boot and whether it ended cleanly
silt -plain     # text, for pipes and ssh (the default when stdout isn't a tty)
silt -plain -new  # only what the boots before didn't have
```

Keys: `tab`/`1`–`4` views, `j`/`k` move, `enter` details with surrounding lines,
`/` search, `+` new only, `b` pick a boot, `n` toggle noise, `q` quit.

Reading the system journal needs the `systemd-journal` or `wheel` group.

NixOS: add the flake as an input (`inputs.nixpkgs.follows = "nixpkgs"`; that
nixpkgs needs `zig_0_17`), import `silt.nixosModules.default`, and set

```nix
programs.silt = {
  enable = true;
  # users = ["alice"];  # adds them to systemd-journal; not needed for wheel
};
```

Build: `nix develop path:. -c zig build`, or `nix build path:.`. A bare
`zig build` needs Zig 0.17, pkg-config and libsystemd's development files, which
NixOS only has inside the dev shell.
