<div align="center">

# 🔌 chrome-fixed-port

**Keeps _every_ Chrome launch opening with `--remote-debugging-port=9225` - update-safe, because the running browser never depends on a directory Google's installer is willing to delete.**

![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)
![Browser](https://img.shields.io/badge/Google%20Chrome-4285F4?logo=googlechrome&logoColor=white)
![Update-safe](https://img.shields.io/badge/hardlink%20mirror-2ea44f)
![Install](https://img.shields.io/badge/install-one%20line-blue)
![License](https://img.shields.io/badge/license-MIT-green)

<sub>Replaces <code>chrome.exe</code> with a small wrapper that launches a private hardlink mirror of Chrome · costs ~0 disk · idempotent, safe to re-run.</sub>

</div>

---

## ⚡ Quick start

```powershell
irm https://raw.githubusercontent.com/Adi1231234/chrome-fixed-port/main/install.ps1 | iex
```

Downloads `run.ps1` + `lib/` to a temp folder, runs it once, cleans up. **Idempotent.**
To stay applied across Chrome updates, **run it periodically from your own scheduled task**.
*(Cloned the repo instead? Just run `./run.ps1`.)*

## The problem this solves

Chrome is multi-process. Every process loads `<version>\chrome.dll` and the resources
beside it, and a **new** renderer re-opens those files from disk when it starts.
Delete them out from under a running browser and existing tabs keep working while
every new tab dies instantly with `STATUS_BREAKPOINT`.

That is exactly what Google's own installer does to this tool's predecessor.
`chrome/installer/util/delete_old_versions.cc` classifies a version directory by a
single test (line 91): does a file matching the glob `old_chrome*.exe` with a
matching `FileVersion` sit next to it?

- **Yes** -> `DeleteVersion()`, which tries to lock every `.exe`/`.dll` first.
- **No** -> `"Attempting to delete stray directory"` -> `DeletePathRecursively()`,
  **with no in-use check at all**.

The old design named the genuine launcher `chrome_real_<version>.exe`, which matches
no glob Chrome knows, so the directory of the *running* browser was purged as stray.
Measured on this machine: 18 files and all 8 subdirectories deleted, leaving only the
7 mapped `.dll`s that Windows refuses to unlink. `icudtl.dat` was among the casualties,
and it is the one file whose absence is fatal.

Renaming to `old_chrome_<version>.exe` does **not** fix it. `DeleteVersion()`'s lock is
opened with `GENERIC_READ` and `FILE_SHARE_DELETE` only, and a mapped image does not
hold a conflicting file object - so that lock **succeeds** on a `chrome.dll` loaded by
34 live processes, and the function proceeds to the same `DeletePathRecursively()`.
Verified against `kernel32.dll` and a running `powershell.exe`, with passing controls.
Both routes end at the same call. Only *exclusion* protects a directory, and Chrome
excludes exactly two: the ones matching `chrome.exe` and `new_chrome.exe`'s `FileVersion`.

## The design

Do not fight the installer for ownership of a directory. Do not depend on that
directory at all.

- **`chrome.exe`** is our wrapper. It finds the newest mirror, injects the debug
  flags, launches it, and **waits**, returning the browser's real exit code.
- **The mirror** lives at `%LOCALAPPDATA%\ChromeFixedPort\<version>\` and is a
  self-contained Chrome install built from **NTFS hardlinks**:
  `chrome.exe` plus `<version>\`. Google's installer has never heard of this path.
- A hardlink is a second name for the same data. When Google unlinks its own name,
  the data survives because ours still references it. Measured: 265 links to a
  483 MB tree consumed **0.1 MB**.
- **The wrapper carries a real `FileVersion`** (the version it launches), so Chrome's
  own install stays excluded from its own cleanup instead of being purged as stray.
  An unstamped wrapper reports `0.0.0.0` and excludes nothing.

## Why a mirror can be trusted

A mirror is only marked complete once the source version directory actually
contains what a renderer needs (`chrome.dll`, `icudtl.dat`). This matters because
Google's cleanup deletes everything it can and leaves the mapped `.dll` files
behind - so a half-purged directory still looks populated, and mirroring one would
faithfully reproduce a browser that dies on every new tab.

One genuine launcher, `chrome_real_<newest>.exe`, is kept beside Chrome, hardlinked
from the mirror so it costs nothing. It is the seed the mirror is rebuilt from if
the mirror is ever damaged or deleted.

## No file clutter

`run.ps1` keeps the newest mirror plus any mirror with a live process, and deletes the
rest - which is what actually reclaims the disk, since after Google unlinks its copy
our hardlink is the data's last reference. Steady state is one mirror costing nothing;
worst case two, only between an update and your next Chrome restart.

Liveness is decided by `Test-Locked`, which asks for **write** access. A mapped image
denies writes, so it correctly reports a version still in use - the very check Chrome's
installer gets wrong by asking only for read.

## Notes

- `CHROME_WRAP_OVERRIDE` overrides the injected flags.
- The wrapper also injects `--enable-features=CDPScreenshotNewSurface`. Without it, CDP
  `Page.captureScreenshot` hangs forever whenever the Chrome window is minimised -
  no error, no timeout - so any agent driving the browser stalls until you restore the
  window. Chromium ships the fix disabled by default (crbug.com/377715191). Skipped if
  you pass your own `--enable-features`, since Chrome honours only one such flag.
- `run.ps1` also swaps Google's staged `new_chrome_proxy.exe` into `chrome_proxy.exe`.
  Chrome normally does that in its rename step, which never runs here: it looks for
  `new_chrome.exe` next to the *running* binary, and ours runs from the mirror. Left
  alone, `chrome_proxy.exe` freezes at an old version and every PWA shortcut fails to
  start with "the side-by-side configuration is incorrect" once Google prunes that
  version directory.
- `CHROME_FIXED_PORT_DIR` overrides Chrome's Application directory (for testing).
- `CHROME_FIXED_PORT_MIRROR` overrides the mirror root (for testing).
- `$WRAPPER_VER` + the `.wrapper_ver` marker (`<ver>|<stamped version>`) force a reinstall.
- The wrapper injects `--user-data-dir=%LOCALAPPDATA%\Google\ChromeDebug`. Check whether
  that path is a junction to your real profile - if it is, the debug port drives your
  real session, and CDP has no authentication.
- Hardlinks need one NTFS volume; `Sync-Mirror` falls back to a real copy otherwise.
