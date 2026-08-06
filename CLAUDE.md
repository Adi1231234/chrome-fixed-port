# Project guide (for contributors and agents)

A tiny tool that keeps **every** Chrome launch opening on a fixed
`--remote-debugging-port` by replacing `chrome.exe` with a wrapper, without ever
overwriting the binary a running browser uses. Read this before changing anything
so the structure and the safety guarantees stay intact.

## Layout

- **`install.ps1`** - one-line bootstrap: downloads `run.ps1` + `lib/` to a temp
  folder, runs it once, cleans up. No scheduling - the user wires their own timer.
  Users never edit this.
- **`run.ps1`** - the core tool: compiles the wrapper, applies it, cleans up. Runs
  standalone; `lib/` only adds the icon. Meant to run periodically from a scheduled
  task (keep `lib/` next to it).
- **`lib/Get-ExeIcon.ps1`** - the one optional concern split out of `run.ps1`:
  extracts Chrome's icon so the wrapper isn't icon-less. Dot-sourced if present.
- **`README.md`** - user-facing write-up: the problem, the design, the proof.

## The moving parts

- `$wrapperSrc` (in `run.ps1`) - the C# wrapper source. On launch it finds the
  **newest** `chrome_real_<version>.exe` and runs it, injecting the debug flags. Keep
  it small; it must not read user paths from anything but `%LOCALAPPDATA%` / env overrides.
- `New-Wrapper` (in `run.ps1`) - compiles `$wrapperSrc` with the .NET Framework
  `csc.exe` in a throwaway temp dir. If `lib/Get-ExeIcon.ps1` is loaded it calls
  `Resolve-WrapperIcon` and compiles with `-win32icon` so shortcuts that read
  `chrome.exe,0` show Chrome's icon; if not, it builds an icon-less wrapper. Caller
  removes the temp dir in `finally`.
- `lib/Get-ExeIcon.ps1` - `Export-ExeIcon` rebuilds a multi-resolution `.ico` from a
  PE's first icon group (RT_GROUP_ICON + RT_ICON; the group name is a wide string, so
  it needs `EnumResourceNamesW`); `Resolve-WrapperIcon` picks the genuine source exe
  and extracts. Fail-safe: any failure yields an icon-less wrapper, never a failed run.
- `Save-Genuine` - moves a genuine launcher into `chrome_real_<ver>.exe`, one
  **immutable copy per version**; never overwrites an existing copy.
- `Test-Google` / `Test-Locked` - signature check and in-use check; the two guards
  every destructive step consults before acting.
- `STEP 1/2/3` in the main body - ride Google's swap, ensure `chrome.exe` is our
  wrapper, then sweep stale `chrome_real_*.exe`.

## Non-negotiable conventions

- **Never touch a binary a running browser uses.** This is the whole point. Before
  any overwrite/delete, check `Test-Locked` and `Test-Google`. A locked or genuine
  target is **deferred to the next run**, never forced.
- **Immutable per-version launchers.** `chrome_real_<ver>.exe` is written once and
  never overwritten - updates only *add* a new version. This is what stops the
  version skew that crashes tabs.
- **Fail-safe, defer don't corrupt.** If a step cannot run safely this pass (locked
  file, missing dir), log a `WARN` and leave state untouched so the next run retries.
  Never write a partial or guessed state.
- **Idempotent.** Re-running must converge, not double-apply. The `.wrapper_ver`
  marker + `$WRAPPER_VER` gate reinstalls; bump `$WRAPPER_VER` only when
  `$wrapperSrc` actually changes.
- **Cleanup is surgical.** Only ever touch files matching `chrome_real_*.exe` (and
  legacy `chrome_real_old_*.exe`). Never `chrome_proxy.exe`, the `<version>\` dirs,
  or any other genuine Chrome file.
- **No hardcoded user paths, no secrets.** Everything derives from `%LOCALAPPDATA%`
  or the `CHROME_FIXED_PORT_DIR` / `CHROME_WRAP_OVERRIDE` env overrides.
- **Approved PowerShell verbs, ASCII-safe.** Use `Verb-Noun` with approved verbs;
  keep the script BOM-free and free of non-ASCII glyphs.
- **File size.** Keep each file small and single-purpose. If `run.ps1` grows past
  ~150 lines or takes on a second responsibility, split the new concern into its own
  script rather than letting it sprawl.

## Testing a change (without touching your real install)

1. Point the tool at a fake, isolated Application dir:
   `$env:CHROME_FIXED_PORT_DIR = '<tmp>\Application'` and create it.
2. Drop a couple of fake `chrome_real_<ver>.exe` and a signed/unsigned
   `new_chrome.exe` to exercise `STEP 1` and the cleanup.
3. Run `./run.ps1`, then run it **again** and confirm the second pass is a no-op
   (installed wrapper reported, nothing re-copied) - that proves idempotency.
4. Verify the cleanup kept only the newest + any locked copy, and touched nothing
   outside `chrome_real_*.exe`.
