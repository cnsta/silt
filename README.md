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
- **Last 60s**: everything logged right before the end.
- **pstore**: panics that never reached the journal, if readable.

```
silt            # the previous boot, in a TUI
silt -b -3      # boot offsets are journalctl's
silt -list      # every boot and whether it ended cleanly
silt -plain     # text, for pipes and ssh (the default when stdout isn't a tty)
```

Keys: `tab`/`1`–`4` views, `j`/`k` move, `enter` details with surrounding
lines, `/` search, `b` pick a boot, `n` toggle noise, `q` quit.

Reading the system journal needs the `systemd-journal` or `wheel` group.

Build: `nix develop path:. -c zig build` (Zig 0.17, libsystemd), or
`nix build path:.`.
