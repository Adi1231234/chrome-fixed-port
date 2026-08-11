# Project guide (for contributors and agents)

A tiny tool that keeps **every** Chrome launch opening on a fixed
`--remote-debugging-port` by replacing `chrome.exe` with a wrapper, while the
running browser executes from a private hardlink mirror that Google's installer
cannot reach. Read this before changing anything.

## Layout

- **`install.ps1`** - one-line bootstrap: downloads `run.ps1` + `lib/`, runs it once,
  cleans up. No scheduling - the user wires their own timer. Users never edit this.
- **`run.ps1`** - thin orchestrator: mirror, install wrapper, cleanup. Needs `lib/`.
- **`lib/Common.ps1`** - logging, path resolution, version parsing, and the guards.
- **`lib/Mirror.ps1`** - builds and prunes the hardlink mirror.
- **`lib/Wrapper.ps1`** - the C# wrapper source and its compile step.
- **`lib/Get-ExeIcon.ps1`** - optional: extracts Chrome's icon. Dot-sourced if present.
- **`README.md`** - the problem, the design, the proof.

## The root cause this design exists to avoid

Chrome's `chrome/installer/util/delete_old_versions.cc` decides a version
directory's fate on **one** test (line 91): is there an `old_chrome*.exe` next to
it whose `FileVersion` matches? If not, it is a "stray directory" and gets
`DeletePathRecursively()` **with no in-use check**. A running browser is not
consulted, and `icudtl.dat` is the file whose loss kills every new renderer with
`STATUS_BREAKPOINT` while existing tabs keep working.

Two things that look like fixes and are not:

- **Renaming the stashed launcher to `old_chrome_<ver>.exe`.** That routes to
  `DeleteVersion()`, whose lock (`GetFileLock`, line 139) opens with `GENERIC_READ`
  and `FILE_SHARE_DELETE` only. A mapped image holds no conflicting file object, so
  that lock **succeeds** on a loaded `chrome.dll`, and the function falls through to
  the same `DeletePathRecursively()`. Verified with passing controls.
- **Testing whether the version directory is "locked" the way Chrome does.** Same
  reason. Ask for **write** access instead (`Test-Locked`) - that is what a mapped
  image actually denies.

Only *exclusion* protects a directory, and Chrome excludes exactly two: the ones
named after `chrome.exe`'s and `new_chrome.exe`'s `FileVersion`.

## Non-negotiable conventions

- **The running browser never depends on Chrome's Application directory.** It runs
  from `%LOCALAPPDATA%\ChromeFixedPort\<version>\`. If a change reintroduces a
  dependency on Google's directory at browser runtime, it reintroduces the bug.
- **Never mirror a version directory that cannot run.** Google's cleanup strips
  everything it can and leaves the mapped `.dll` files behind, so a half-deleted
  directory still *looks* populated - mirroring one reproduces the original bug
  faithfully, and an empty directory yields a "complete" mirror of nothing.
  `Test-VersionUsable` gates this on `$RequiredFiles`; `icudtl.dat` is the file
  measured to be fatal.
- **Only build what you keep.** Compute the keep set (newest servable version plus
  anything with a live process) *before* syncing. Building a mirror the very same
  run then prunes it is pure churn, and it never converges.
- **Always leave one genuine launcher beside Chrome.** `chrome_real_<newest>.exe`
  is hardlinked from the mirror, so it costs nothing and is the seed the mirror is
  rebuilt from. Without it the mirror's own `chrome.exe` is the only genuine
  launcher on the machine and losing it is unrecoverable.
- **Flags are tokens, not substrings.** The wrapper must match an argument that
  *starts with* a flag. A plain `IndexOf` lets a URL like
  `https://x/?q=--type=renderer` masquerade as a flag and silently kill the port.
- **Mirror before you overwrite.** `run.ps1` STEP 1 mirrors every genuine launcher
  it can see *before* anything replaces `chrome.exe` or `new_chrome.exe`.
- **Replace files by unlinking first.** `Set-FileFresh` removes the target before
  copying. Overwriting in place writes *through* the hardlink and corrupts the
  mirror - this is the single easiest way to break this design.
- **Stamp the wrapper.** `New-Wrapper` requires a version. An unstamped wrapper
  reports `0.0.0.0`, excludes nothing, and leaves Chrome's own install purgeable.
- **Fail-safe, defer don't corrupt.** A locked or missing target logs a `WARN` and
  is retried next run. Never write a partial or guessed state.
- **Idempotent.** Re-running must converge. The `.wrapper_ver` marker holds
  `<WRAPPER_VER>|<stamped version>`; bump `$WRAPPER_VER` only when `$wrapperSrc` changes.
- **Cleanup is surgical.** Only ever touch our own mirror directories and the legacy
  `chrome_real_*.exe`. Never `chrome_proxy.exe` or any other genuine Chrome file.
- **No hardcoded user paths, no secrets.** Everything derives from `%LOCALAPPDATA%`
  or the `CHROME_FIXED_PORT_DIR` / `CHROME_FIXED_PORT_MIRROR` / `CHROME_WRAP_OVERRIDE`
  overrides.
- **Approved PowerShell verbs, ASCII-safe, BOM-free.**
- **File size.** Keep every file under 150 lines and single-purpose.

## Testing a change (without touching your real install)

1. Point both roots at throwaway directories:
   `$env:CHROME_FIXED_PORT_DIR`, `$env:CHROME_FIXED_PORT_MIRROR`.
2. Seed the fake Application dir with a **genuine signed** launcher (copy one out of a
   real install, `Test-Google` must pass) and a `<version>\` directory beside it.
3. Run `./run.ps1`, then run it **again** - the second pass must be a clean no-op.
4. Assert the mirror launcher is still ~4 MB and genuine. If it is wrapper-sized, some
   code overwrote a file in place and wrote through the hardlink.
5. Delete the fake `<version>\` directory and confirm the mirror survives with content.
6. To exercise the browser, set `CHROME_WRAP_OVERRIDE` to a **distinct port and a
   throwaway `--user-data-dir`**. The default injects the real `ChromeDebug` profile
   and will hand off to your running browser instead of testing anything.
7. Beware the render check: creating a tab and polling for its `<title>` is **flaky in
   headless mode** (roughly one in three fails with nothing purged). Always run the
   no-purge control before believing a failure, and test several tabs.
