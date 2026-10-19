<div align="center">

# 🔌 chrome-fixed-port

**Keeps _every_ Chrome launch opening with `--remote-debugging-port=9225` - update-safe, because the running browser never depends on a directory Google's installer is willing to delete.**

![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)
![Browser](https://img.shields.io/badge/Google%20Chrome-4285F4?logo=googlechrome&logoColor=white)
![Update-safe](https://img.shields.io/badge/hardlink%20mirror-2ea44f)
![Install](https://img.shields.io/badge/install-one%20line-blue)
![License](https://img.shields.io/badge/license-MIT-green)

<sub>Windows redirects every start of <code>chrome.exe</code> to a small wrapper that launches a private hardlink mirror of Chrome · survives Chrome updates with no re-run · costs ~0 disk · idempotent, safe to re-run.</sub>

</div>

---

## ⚡ Quick start

```powershell
irm https://raw.githubusercontent.com/Adi1231234/chrome-fixed-port/main/install.ps1 | iex
```

Downloads `run.ps1` + `lib/` to a temp folder, runs it once, cleans up. **Idempotent.**
The first run asks for admin once, to write the launch redirect. Chrome updates do not
undo it. A periodic run from your own scheduled task only moves the mirror to the newest
Chrome version; until then the previous version keeps opening, with the port.
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

- **`chrome.exe` stays Google's.** An Image File Execution Options entry (`UseFilter`
  + `FilterFullPath`) makes Windows run our wrapper whenever Chrome's own `chrome.exe`
  is started - by the taskbar, a file association, a link, anything. It lives in the
  registry, keyed by path, so a Chrome update that replaces the file does not undo it.
- **The wrapper** (`%LOCALAPPDATA%\ChromeFixedPort\chrome-fixed-port.exe`) finds the
  newest mirror, injects the debug flags, launches it, and **waits**, returning the
  browser's real exit code. A `--headless` launch is a script's own browser and is
  passed through untouched, like Chrome's child processes.
- **The mirror** lives at `%LOCALAPPDATA%\ChromeFixedPort\<version>\` and is a
  self-contained Chrome install: `<version>\` built from **NTFS hardlinks**, plus a
  copy of `chrome.exe`. Google's installer has never heard of this path. The launcher
  is copied, not linked, because a link is the same file as Chrome's own `chrome.exe`:
  a browser running from it would make Google find `chrome.exe` in use and defer its
  update to a rename step that never runs from the mirror.
- A hardlink is a second name for the same data. When Google unlinks its own name,
  the data survives because ours still references it. Measured: 265 links to a
  483 MB tree consumed **0.1 MB**.
- The mirror's `chrome.exe` has the same name at a different path, so the redirect
  never touches the running browser or the processes it spawns.
- Earlier versions overwrote `chrome.exe` with the wrapper. Every Chrome update put
  Google's file back, and until the next run Chrome opened without the port. A run
  of this version undoes that and gives `chrome.exe` back to Google.

## Why a mirror can be trusted

A mirror is only marked complete once the source version directory actually
contains what a renderer needs (`chrome.dll`, `icudtl.dat`). This matters because
Google's cleanup deletes everything it can and leaves the mapped `.dll` files
behind - so a half-purged directory still looks populated, and mirroring one would
faithfully reproduce a browser that dies on every new tab.

If the mirror is ever damaged or deleted, it is rebuilt from Chrome's own `chrome.exe`,
which is always Google's genuine launcher now.

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
- Nothing runs Chrome's `chrome.exe` any more, so Google's installer always updates
  `chrome.exe` and `chrome_proxy.exe` in place. The old design kept `chrome.exe` busy,
  which made Google defer that swap to a rename step that never ran from the mirror,
  and `chrome_proxy.exe` froze until every PWA shortcut died.
- To remove the tool: delete the subkey `ChromeFixedPort-*` under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\chrome.exe`
  (`Remove-LaunchRedirect` in `lib/Redirect.ps1` does it), then delete
  `%LOCALAPPDATA%\ChromeFixedPort`. In the other order Chrome cannot start, because
  Windows would still send it to a wrapper that is gone.
- `CHROME_FIXED_PORT_DIR` overrides Chrome's Application directory (for testing).
- `CHROME_FIXED_PORT_MIRROR` overrides the mirror root (for testing).
- `chrome-fixed-port.exe.ver` beside the wrapper holds its fingerprint, a hash of the
  wrapper's own source, so editing it is enough to reinstall - there is no version
  number to remember to bump.
- The wrapper injects `--user-data-dir=%LOCALAPPDATA%\Google\ChromeDebug`. Check whether
  that path is a junction to your real profile - if it is, the debug port drives your
  real session, and CDP has no authentication. It must not be `User Data` itself:
  Chrome 136+ ignores `--remote-debugging-port` on the default data directory path.
- Hardlinks need one NTFS volume; `Sync-Mirror` falls back to a real copy otherwise.
