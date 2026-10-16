# Project guide (for contributors and agents)

A tiny tool that keeps **every** Chrome launch opening on a fixed
`--remote-debugging-port`. Windows redirects every start of Chrome's own `chrome.exe`
to a wrapper (Image File Execution Options), and the running browser executes from a
private hardlink mirror that Google's installer cannot reach. Read this before
changing anything.

## Layout

- **`install.ps1`** - one-line bootstrap: downloads the branch archive, runs it once,
  cleans up. No scheduling - the user wires their own timer. Users never edit this.
- **`run.ps1`** - thin orchestrator: mirror, install wrapper, redirect, legacy cleanup.
- **`lib/Common.ps1`** - logging, paths, versions, the guards, and the shared layout.
- **`lib/Mirror.ps1`** - builds and prunes the hardlink mirror.
- **`lib/Wrapper.ps1`** - the C# wrapper source, with the layout substituted in.
- **`lib/Build.ps1`** - the wrapper's identity (a hash of that source), compile, install.
- **`lib/Redirect.ps1`** - the IFEO redirect from Chrome's `chrome.exe` to the wrapper.
- **`lib/Legacy.ps1`** - undoes the old design, which overwrote `chrome.exe` itself.
- **`tests/Run-All.ps1`** - every suite, one summary; a SKIP is reported like a failure.
- **`tests/Test-*.ps1`** - one suite per contract: bootstrap completeness, wrapper
  identity, injected flags, the redirect against real Windows, legacy cleanup.
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
- **Never put the wrapper at `chrome.exe`.** That was the old design. Google's installer
  replaces `chrome.exe` on every update - in place when nothing runs it, which is always
  the case once the browser runs from the mirror (log: `Version updated to X` with no
  `while running`). The wrapper was then gone until the next run. Measured 2026-10-16:
  update at 00:01, an HTML file opened genuine Chrome on the same profile under the
  `User Data` name, and the taskbar pin (`--user-data-dir=...ChromeDebug`) exited with
  code 21, profile in use, showing nothing. The IFEO redirect is keyed by path in the
  registry and survives the file being replaced; nothing needs to run after an update.
- **The redirect is filtered to one path.** `UseFilter=1` + `FilterFullPath` redirect
  only Chrome's Application `chrome.exe`. The mirror's `chrome.exe` shares the name but
  not the path, so the browser and every child it spawns run untouched - an unfiltered
  redirect would route every renderer through the wrapper. One subkey per path hash, so
  a test or another user never overwrites this install's filter. Never `New-Item -Force`
  an existing registry key: that recreates it and wipes other software's values.
- **Keep `--user-data-dir` pointing at `ChromeDebug`, never at `User Data`.** Chrome 136+
  ignores `--remote-debugging-port` on the default data directory path. `ChromeDebug` is
  a junction to the real profile, a different path string, which is why the port works.
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
- **Nothing may run Chrome's `chrome.exe`, so Google always updates in place.** While
  the old wrapper held it, Google staged `new_chrome.exe` / `new_chrome_proxy.exe` for a
  rename step gated on `PathExists(DIR_EXE + "new_chrome.exe")`; `DIR_EXE` is the mirror,
  so it never ran, `chrome_proxy.exe` froze and **every PWA shortcut died** (measured
  2026-08-20). With `chrome.exe` genuine and idle, Google swaps both files itself.
- **No invariant a human must remember; derive it, do not assert it.** Three have
  bitten: `install.ps1`'s file list vs `lib/`, `$WRAPPER_VER` vs `$wrapperSrc`, and the
  mirror layout vs the C# wrapper. All three are now derived, so nothing is left to keep
  in sync: the installer ships the branch archive, the wrapper's identity hashes the
  source it compiles, and the mirror's location *and* layout - `$MirrorRootEnv`,
  `$MirrorRootName`, `$MirrorLauncher`, `$MirrorSentinel`, and the redirected
  `$ChromeImage` the wrapper must drop from its arguments - live once in
  `lib/Common.ps1` and are substituted into the C#. Find them by a mechanical sweep for
  literals written in two files, not judgement. Deleting a copy beats a test that
  catches divergence. Whatever the wrapper is generated from must be what the
  fingerprint hashes, or a change compiles into a wrapper the marker calls installed.
- **Replace files by unlinking first.** `Set-FileFresh` removes the target before
  copying. Overwriting in place writes *through* the hardlink and corrupts the
  mirror - this is the single easiest way to break this design.
- **Fail-safe, defer don't corrupt.** A locked or missing target logs a `WARN` and
  is retried next run. Never write a partial or guessed state.
- **Idempotent.** Re-running must converge. `chrome-fixed-port.exe.ver` beside the
  wrapper holds its fingerprint, a hash of `$wrapperSrc` (`Get-WrapperFingerprint`), so
  editing the wrapper reinstalls it by itself. A wrapper still running a browser is
  renamed aside (NTFS allows that for a running exe) and swept up later.
  **Never make it a literal to bump by hand** - that was the old scheme, and editing
  `$wrapperSrc` without bumping was proven to never reach Chrome at all.
- **Cleanup is surgical.** Only ever *delete* our own mirror directories, retired
  wrappers, and the old design's files (`lib/Legacy.ps1`: `chrome_real_*.exe`,
  `.wrapper_ver`, a non-genuine `new_chrome.exe`, mirror `new_chrome.exe` triggers).
  Never delete a genuine Chrome file. The one sanctioned replacement is a non-genuine
  `chrome.exe`, given back to Google: only with a `Test-Google` launcher whose version
  directory is present, never with a guess.
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
   It writes a real HKLM redirect for the fake path (harmless, its own subkey); remove
   it afterwards with `Remove-LaunchRedirect 'chrome.exe' <fake>\chrome.exe`.
4. Assert the mirror launcher is still ~4 MB and genuine. If it is wrapper-sized, some
   code overwrote a file in place and wrote through the hardlink.
5. Delete the fake `<version>\` directory and confirm the mirror survives with content.
6. To exercise the browser, set `CHROME_WRAP_OVERRIDE` to a **distinct port and a
   throwaway `--user-data-dir`**. The default injects the real `ChromeDebug` profile
   and will hand off to your running browser instead of testing anything.
7. Beware the render check: creating a tab and polling for its `<title>` is **flaky in
   headless mode** (roughly one in three fails with nothing purged). Always run the
   no-purge control before believing a failure, and test several tabs.
