# Project guide (for contributors and agents)

A tiny tool that keeps **every** Chrome launch opening on a fixed
`--remote-debugging-port` by replacing `chrome.exe` with a wrapper, while the
running browser executes from a private hardlink mirror that Google's installer
cannot reach. Read this before changing anything.

## Layout

- **`install.ps1`** - one-line bootstrap: downloads the branch archive, runs it once,
  cleans up. No scheduling - the user wires their own timer. Users never edit this.
- **`run.ps1`** - thin orchestrator: mirror, install wrapper, finish the update, cleanup.
- **`lib/Common.ps1`** - logging, paths, versions, the guards, and the mirror layout.
- **`lib/Mirror.ps1`** - builds and prunes the hardlink mirror.
- **`lib/Wrapper.ps1`** - the C# wrapper source, with the mirror layout substituted in.
- **`lib/Build.ps1`** - the wrapper's identity (a hash of that source) and its compile.
- **`lib/Update.ps1`** - finishes the update Chrome's own rename never gets to finish.
- **`lib/Get-ExeIcon.ps1`** - optional: Chrome's icon. Dot-sourced if present.
- **`tests/Run-All.ps1`** - every suite, one summary; a SKIP is reported like a failure.
- **`tests/Test-*.ps1`** - one suite per contract: bootstrap completeness, wrapper
  identity, injected flags, proxy sync, rename arming, rename safety.
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
- **Keep `--enable-features=CDPScreenshotNewSurface`.** CDP `Page.captureScreenshot`
  queues a `viz::CopyOutputRequest` against the renderer's current `LocalSurfaceId`,
  dequeued only when the window draws or a newer surface activates. A **minimised**
  window does neither, so the call hangs forever - no error, no timeout. The feature
  allocates a `LocalSurfaceId` per capture, the dequeue event. Measured on
  151.0.7922.138: 5/5 stalls without, 0/5 with, ~42ms, no memory growth over 200
  captures. Chromium ships it `FEATURE_DISABLED_BY_DEFAULT`, still does on trunk
  (crbug.com/377715191). Never "fix" a stall with `fromSurface:false` - while minimised
  that returns an all-white PNG. Only minimisation triggers it.
- **Let Chrome finish its own update; cover the proxy anyway.** Chrome's rename moves
  `new_chrome.exe` -> `chrome.exe` AND `new_chrome_proxy.exe` -> `chrome_proxy.exe`,
  re-registers `chrome_wer.dll` and prunes old versions. It runs that step on one test,
  pinned with six trace variants: `PathExists(base::DIR_EXE + "new_chrome.exe")` -
  sensitive to the exact name and directory, indifferent to what it finds. `DIR_EXE` is
  the **running** binary's directory, here the mirror, which `Sync-Mirror` never gives a
  `new_chrome.exe`. So the step is skipped forever. `Sync-PendingRename` restores the
  precondition so Chrome does its real rename and finalises everything, including parts
  we do not model. **Only arm once that file is the wrapper:** the rename *moves* it
  onto `chrome.exe`, and STEP 5 leaves it genuine while its version is unmirrored, so
  arming then evicts the wrapper and drops the debug port. `Sync-ChromeProxy` does the
  proxy half immediately, so nothing is exposed while waiting for that browser start.
  Without them `chrome_proxy.exe` freezes and **every PWA shortcut dies** once Google
  prunes the version directory its manifest names. Measured: stranded on
  151.0.7922.109, killed 2026-08-20 21:51:12. Pruning does **not** wait for the rename
  (`install.cc:489` runs `DeleteOldVersions` in-process on every install).
- **No invariant a human must remember; derive it, do not assert it.** Three have
  bitten: `install.ps1`'s file list vs `lib/`, `$WRAPPER_VER` vs `$wrapperSrc`, and the
  mirror layout vs the C# wrapper. All three are now derived, so nothing is left to keep
  in sync: the installer ships the branch archive, the wrapper's identity hashes the
  source it compiles, and `$MirrorLauncher` / `$MirrorSentinel` live once in
  `lib/Common.ps1` and are substituted into the C#. A test that catches divergence is
  the weaker answer - it lets both copies live. Deleting one is the stronger one. And
  whatever the wrapper is generated from must be what the fingerprint hashes, or a new
  layout compiles into a wrapper the marker calls already installed.
- **Mirror before you overwrite.** `run.ps1` STEP 1 mirrors every genuine launcher
  it can see *before* anything replaces `chrome.exe` or `new_chrome.exe`.
- **Replace files by unlinking first.** `Set-FileFresh` removes the target before
  copying. Overwriting in place writes *through* the hardlink and corrupts the
  mirror - this is the single easiest way to break this design.
- **Stamp the wrapper.** `New-Wrapper` requires a version. An unstamped wrapper
  reports `0.0.0.0`, excludes nothing, and leaves Chrome's own install purgeable.
- **Fail-safe, defer don't corrupt.** A locked or missing target logs a `WARN` and
  is retried next run. Never write a partial or guessed state.
- **Idempotent.** Re-running must converge. `.wrapper_ver` holds
  `<wrapper fingerprint>|<stamped version>`; the fingerprint hashes `$wrapperSrc`
  (`Get-WrapperFingerprint`), so editing the wrapper reinstalls it by itself.
  **Never make it a literal to bump by hand** - that was the old scheme, and editing
  `$wrapperSrc` without bumping was proven to never reach Chrome at all.
- **Cleanup is surgical.** Only ever *delete* our own mirror directories and the legacy
  `chrome_real_*.exe`. Never delete `chrome_proxy.exe` or any other genuine Chrome file.
  `lib/Update.ps1` holds the only sanctioned exceptions: it *replaces*
  `chrome_proxy.exe` with Google's own staged `new_chrome_proxy.exe`, never with
  anything we made and only after `Test-Google` passes, and it links (never moves)
  the staged `new_chrome.exe` into the mirror.
- **No hardcoded user paths, no secrets.** Everything derives from `%LOCALAPPDATA%`
  or the `CHROME_FIXED_PORT_DIR` / `CHROME_FIXED_PORT_MIRROR` / `CHROME_WRAP_OVERRIDE`
  overrides.
- **Approved PowerShell verbs, ASCII-safe, BOM-free.**
- **File size.** Keep every file under 150 lines and single-purpose.

## Testing a change (without touching your real install)

0. Run `./tests/Run-All.ps1` - every suite, one summary. A **SKIPPED** suite asserts
   nothing: a pinned Chrome version once made one skip for days unnoticed, so treat a
   skip as a failure until you know why.
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
