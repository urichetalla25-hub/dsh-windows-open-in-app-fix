# Changelog

## 0.1.0 - 2026-11-17

- First public release.
- `install.ps1`: locates DSH Desktop, verifies the open-in-app launcher shape,
  removes the inherited `ELECTRON_RUN_AS_NODE` flag with a byte-length-preserving
  patch, backs up the full `app.asar`, verifies the write and runs a syntax check.
- `uninstall.ps1`: restores the original launcher bytes from the backup.
- Verified against DSH Desktop 0.2.2-rc.3 on Windows 11 x64 (Electron 44 / Node 24).
- Tested: dry run, apply, idempotent re-run, rollback, byte-identical restore,
  and refusal on an unrecognized launcher shape.
