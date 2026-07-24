# chrome-fixed-port

Keeps **every** Chrome launch opening with `--remote-debugging-port=9225` (on a
separate `ChromeDebug` profile), by replacing `chrome.exe` with a tiny wrapper.
[run.ps1](run.ps1) is meant to be run periodically by a scheduled task.

## The problem this solves

Chrome is multi-process: one browser process plus one process per tab, all
launched from the same launcher `.exe` and all loading the same
`<version>\chrome.dll`. **They must be the exact same version to talk to each
other** - if the browser is version A and a new tab's process is version B, the
tab crashes instantly (sad/blank tab).

Chrome updates itself safely by **never touching the running binary**: it adds a
new `<version>\` folder, stages the new launcher as `new_chrome.exe`, and only
swaps `new_chrome.exe -> chrome.exe` later (done by Google's own
`setup.exe --rename-chrome-exe`, which triggers on the next full Chrome restart).

The previous version of this tool broke that rule. After an update reverted the
wrapper, it re-applied by **overwriting the single fixed-name `chrome_real.exe`
with the new version while the old browser was still running**. The running
browser (version A) then spawned every new tab from `chrome_real.exe`, which was
now version B -> version skew -> every new tab crashed until Chrome was restarted.

## The design

- `chrome.exe` = our wrapper. On launch it finds the **newest**
  `chrome_real_<version>.exe` and runs it, injecting the debug flags.
- `chrome_real_<version>.exe` = the genuine Chrome launcher, **one immutable copy
  per version**. An existing copy is never overwritten; updates only *add* a new
  one. The launcher must stay at the top level so it finds `<version>\chrome.dll`.
- A running browser is launched (by the wrapper) directly as
  `chrome_real_<its version>.exe` and spawns its tabs from that same file. Since
  that file is never overwritten, its tabs never skew.

### On a Chrome update we ride Google's own swap

When Google stages `new_chrome.exe` (it sits there for hours to days before the
swap), the scheduled run:

1. moves `new_chrome.exe` -> `chrome_real_<its version>.exe` (stash the genuine
   new launcher under its version name), then
2. copies the **wrapper** into `new_chrome.exe`.

Google then performs its normal swap and promotes our wrapper to `chrome.exe`.
So `chrome.exe` is always the wrapper - no window without the debug port, no
re-apply race, and nothing a running browser uses is ever touched.

> Verified on this machine: Google's rename step is a blind file move with **no
> signature check** - it promoted a deliberately unsigned `new_chrome.exe` to
> `chrome.exe` (SHA-256 confirmed identical before/after). The one honest caveat
> is that this is undocumented Google behavior that could change in a future
> version; `STEP 2` in the script is the fallback if it ever does.

## No file clutter

`STEP 3` keeps only the **newest** `chrome_real_<version>.exe` plus any copy that
is **locked** (a browser is still running from it), and deletes the rest. A copy
lingers only while genuinely in use; the next run sweeps it once the browser
closes. Steady state is at most two of our files (newest + the running one). The
cleanup only ever touches files matching `chrome_real_*.exe` - never
`chrome_proxy.exe`, the version folders, or any other genuine Chrome file. Old
random-suffix leftovers (`chrome_real_old_*.exe`) from the previous design are
swept too, once unlocked.

## Notes

- Google's swap is triggered by a full Chrome restart, so after installing this
  the first time (or recovering from the old skew) you must close and reopen
  Chrome **once**; from then on updates are handled with no crashes.
- `CHROME_WRAP_OVERRIDE` env var overrides the injected flags.
- `CHROME_FIXED_PORT_DIR` env var overrides the Application directory (used for
  testing against an isolated fake install).
- `$WRAPPER_VER` / the `.wrapper_ver` marker force a wrapper reinstall when the
  wrapper source changes.
