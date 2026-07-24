# Project guide (for contributors and agents)

A tiny tool that keeps **every** Chrome launch opening on a fixed
`--remote-debugging-port` by replacing `chrome.exe` with a wrapper, without ever
overwriting the binary a running browser uses. Read this before changing anything
so the structure and the safety guarantees stay intact.

## Layout

- **`install.ps1`** - one-line bootstrap: downloads `run.ps1` to a temp folder,
  runs it once, cleans up. No scheduling - the user wires their own timer. Users
  never edit this.
- **`run.ps1`** - the whole tool, one self-contained script. Compiles the wrapper,
  applies it, and cleans up. It is meant to run periodically from a scheduled task.
- **`README.md`** - user-facing write-up: the problem, the design, the proof.

## The moving parts (all inside `run.ps1`)

- `$wrapperSrc` - the C# wrapper source. On launch it finds the **newest**
  `chrome_real_<version>.exe` and runs it, injecting the debug flags. Keep it small;
  it must not read user paths from anything but `%LOCALAPPDATA%` / env overrides.
- `New-Wrapper` - compiles `$wrapperSrc` with the .NET Framework `csc.exe` in a
  throwaway temp dir. Caller removes the temp dir in `finally`.
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
