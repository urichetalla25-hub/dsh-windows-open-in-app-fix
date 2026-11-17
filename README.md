# dsh-windows-open-in-app-fix

One-click fix for **"Open in VS Code" fails in DeepSeek Harness Desktop on Windows**
(the UI shows a generic *"Could not open. Try again."* toast).

> Unofficial community workaround. Not affiliated with DeepSeek. Use at your own risk.

## The problem

The DSH desktop shell starts its Host process with `ELECTRON_RUN_AS_NODE=1`.
That variable stays in the Host environment and is inherited by every child
process. The `open-in-app` launcher only strips credential-like variables
(`*KEY*`, `*PASSWORD*`, `*SECRET*`, `*TOKEN*`, `DSH_*`), so the flag reaches
`Code.exe`.

VS Code is itself an Electron app. Started with that flag it runs in **Node
mode**, treats the workspace folder as an entry script, and exits non-zero in
about 50 ms:

```
Error: Cannot find module 'C:\Users\YourName\workspace'
Node.js v24.x
```

The launch watch window then classifies the attempt as failed, and DSH reports
a launch error. Non-Electron targets (File Explorer, Windows Terminal, Git Bash,
JetBrains IDEs) are not affected.

Related upstream discussions:
- https://github.com/deepseek-ai/deepseek-harness/discussions/10404
- https://github.com/deepseek-ai/deepseek-harness/discussions/9920

## The fix

`install.ps1` removes the inherited variable **at the open-in-app launch site
only**:

```
...scrubbedParentEnv(),                      ->  ...((env) => (delete env.ELECTRON_RUN_AS_NODE, env))(scrubbedParentEnv()),
```

The replacement is written inside `resources\app.asar` with a
**byte-length-preserving** edit, so every archive offset stays valid and the
original file can be restored exactly. No registry changes, no global
environment changes, no reinstall.

## Usage

Download this repository (Code > Download ZIP), open PowerShell in the folder, then:

```powershell
# preview only, writes nothing
.\install.ps1 -DryRun

# apply
.\install.ps1

# restore the original file
.\uninstall.ps1
```

Restart DSH Desktop afterwards. The script auto-detects the install folder; use
`-DshRoot "D:\Apps\DeepSeek Harness"` if yours lives elsewhere.

A full copy of the original `app.asar` is stored in
`%LOCALAPPDATA%\dsh-open-in-app-fix\backups` before anything is written.

## Verified environment

| Item | Value |
|---|---|
| DSH Desktop | 0.2.2-rc.3 |
| OS | Windows 11 x64 |
| Electron / Node in the app | Electron 44 / Node 24 |
| Launcher | `@deepseek-ai/dsh-host-open-in-app` as shipped in that build |

Other builds are **not** claimed to work. The script refuses to modify anything
when the launcher code does not match the expected shape, when the launch site
is not unique, when the byte length cannot be preserved, or when the archive
layout is unreadable. In those cases it exits with a message and changes nothing.

## Safety rules the script follows

- verifies the launcher shape and that the match is unique;
- keeps the patched file byte-identical in size (offsets untouched);
- backs up the whole original `app.asar` before writing;
- verifies the write and runs a syntax check when a Node runtime is available;
- is idempotent (detects an already patched install);
- never touches the registry, global env vars, or other applications;
- no telemetry, no network access, no data collection.

## Caveats

- A DSH upgrade replaces `app.asar`, so the fix must be re-applied after each
  update (until upstream stops leaking the variable).
- The patch changes one internal file of the shipped app. Keep the backup; run
  `uninstall.ps1` to return to the original state at any time.
- Tested on the build above only.

## Privacy

The scripts read only `app.asar` inside the DSH install folder and write only to
that file and to the local backup folder. Nothing is uploaded anywhere.

## License

MIT - see [LICENSE](LICENSE).
