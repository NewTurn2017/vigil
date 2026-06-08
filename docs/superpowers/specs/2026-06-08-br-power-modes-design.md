# `br` Power Modes — work / away / sleep

**Date:** 2026-06-08
**Status:** Approved design
**Platform:** macOS (Apple Silicon, macOS 26.x), Swift 6.x
**Builds on:** `2026-06-08-br-brightness-toggle-design.md` (same binary, same agent, same hotkey-config format)

## Summary

Three power "modes" added to `br`, exposed as both CLI subcommands and global
hotkeys, turning `br` into an **Amphetamine replacement**. All three keep the Mac
**awake** (system never idle-sleeps) while controlling the screen, plus an explicit
sleep-now:

| Mode | Hotkey (user) | On press | Ongoing |
|------|---------------|----------|---------|
| `work`  | ⌘⇧0 | brightness → 100% (screen on) | system stays awake; macOS turns the screen off after its idle timer (10 min on AC) |
| `away`  | ⌘⇧9 | display sleep **now** (`pmset displaysleepnow`) | system stays awake |
| `sleep` | ⌘⇧8 | stop keep-awake + sleep **now** (`pmset sleepnow`) | normal on next wake |

`work` and `away` both ensure keep-awake is ON (so the Mac never idle-sleeps —
replacing Amphetamine). `work` turns the screen on; `away` turns it off immediately.
`sleep` exits keep-awake and sleeps the whole Mac.

## Goals

- Replace Amphetamine: keep the system awake reliably, **root-free**, while still
  letting the display turn off (Amphetamine's "keep awake" also keeps the display
  on; we don't).
- One-key access to each mode; user's keys ⌘⇧0 / ⌘⇧9 / ⌘⇧8.
- Easy to reverse: `away`→`work` to bring the screen back; `sleep` or `br awake off`
  to return to normal sleep behavior.

## Non-Goals (YAGNI)

- Custom idle detection / configurable timeout — rely on macOS's own displaysleep
  timer (it is media-aware and covers external displays for free).
- Keeping the **display** awake (no `caffeinate -d`); both modes let the display sleep.
- Per-display control.
- Persisting modes across reboot — modes are **session-scoped**; after a reboot the
  Mac is in normal mode (re-enable with `br work`/`away` or a hotkey).

## CLI Interface (additions)

| Invocation        | Action                                                        |
|-------------------|---------------------------------------------------------------|
| `br work`         | keep-awake ON + brightness 100%                               |
| `br away`         | keep-awake ON + display sleep now                             |
| `br sleep`        | keep-awake OFF + sleep the Mac now                            |
| `br awake on`     | keep-awake ON only (no brightness/display change)             |
| `br awake off`    | keep-awake OFF only (return to normal sleep; does not sleep)  |
| `br awake status` | print `awake: on` / `awake: off`                              |

Existing brightness commands (`br`, `br on`, `br off`, `br <N>`, `br status`) and
clamshell coupling are unchanged. Exit codes follow the existing convention:
`0` success, `1` runtime error, `2` usage error. A failed `pmset`/`launchctl`
prints a concise stderr message; where the primary effect (e.g. brightness) still
succeeded, the command returns `0` with a warning.

## Behavior Details

- **Keep-awake** = a launchd-managed `caffeinate -i` job named `com.genie.br.awake`.
  `-i` prevents idle **system** sleep only; it does **not** prevent display sleep —
  exactly the asymmetry we want. Creating this assertion needs **no root**.
- **`work`**: ensure the awake job is running (idempotent), then set brightness to
  1.0. The hotkey keypress itself wakes a sleeping display; the brightness call then
  guarantees full brightness.
- **`away`**: ensure the awake job is running, then `pmset displaysleepnow`. Any
  later input wakes the display at its previous brightness (chosen behavior).
- **`sleep`**: stop the awake job, then `pmset sleepnow`. On the next wake the Mac is
  in normal mode (no keep-awake).
- **Idempotency**: pressing `work`/`away` repeatedly is safe; `br awake off` when
  already off is a no-op.

## Architecture

Same binary, one new source file plus small additions to existing files:

| File | Addition |
|------|----------|
| `Sources/Awake.swift` (new) | `awakeEnsureOn()`, `awakeOff()`, `awakeIsOn()` (launchctl wrappers for `com.genie.br.awake`); `displaySleepNow()`, `sleepNow()` (pmset); `runWork()`, `runAway()`, `runSleep()` |
| `Sources/CLI.swift` | parse `work` / `away` / `sleep` / `awake on|off|status`; dispatch to the `run*` functions |
| `Sources/Agent.swift` | hotkey actions `work` (id 4) / `away` (id 5) / `sleep` (id 6); accept these in `parseBindings`; `performAction` dispatch |
| `launchd/com.genie.br.awake.plist.template` (new) | runs `/usr/bin/caffeinate -i` |
| `Makefile` | `hotkey-install` also installs + bootstraps the awake job (idle); `hotkey-uninstall` boots it out + removes its plist |

### Keep-awake job (`com.genie.br.awake`)

- Plist: `ProgramArguments = [/usr/bin/caffeinate, -i]`, **`RunAtLoad = false`**, **no
  `KeepAlive`**. Present-but-idle after login → session-scoped (off after reboot).
- `awakeEnsureOn()` → `launchctl kickstart -k gui/$(id -u)/com.genie.br.awake`
  (starts caffeinate; `-k` restarts if already running). Requires the job to be
  bootstrapped (done by `make hotkey-install`, and auto-loaded each login because the
  plist is in `~/Library/LaunchAgents`).
- `awakeOff()` → `launchctl kill SIGTERM gui/$(id -u)/com.genie.br.awake` (stops
  caffeinate; the job stays loaded but idle).
- `awakeIsOn()` → `launchctl print gui/$(id -u)/com.genie.br.awake` shows
  `state = running`.

### pmset actions

- `displaySleepNow()` → `pmset displaysleepnow`; `sleepNow()` → `pmset sleepnow`.
- **Root requirement is verified as the first implementation step** (these are
  *actions*, not *settings*, and are expected to work for the console user without
  root). If verification shows they need root, extend the existing
  `/etc/sudoers.d/br` rule (already used for `pmset disablesleep`) to also allow
  `pmset displaysleepnow` and `pmset sleepnow`, and call them via `sudo -n`.

### Hotkey config (extends the existing format)

Action vocabulary gains `work` / `away` / `sleep`. The user's config becomes:

```conf
work  = cmd+shift+0
away  = cmd+shift+9
sleep = cmd+shift+8
```

`parseBindings` maps these to `HotkeyAction` cases `.work` / `.away` / `.sleep`;
`actionID` assigns ids 4 / 5 / 6; `performAction(id:)` dispatches to
`runWork()` / `runAway()` / `runSleep()`. (Existing `on`/`off`/`toggle` and the
default `⌃⌥⌘B` toggle are unchanged.) The current installed config
(`on = cmd+shift+0`, `off = cmd+shift+9`) is rewritten to the three lines above and
the agent reloaded.

## Error Handling

| Condition                                   | Output (stderr)                                   | Exit |
|---------------------------------------------|---------------------------------------------------|------|
| awake job not loaded (kickstart fails)      | `br: keep-awake unavailable — run: make hotkey-install` | 1 |
| `pmset displaysleepnow`/`sleepnow` fails    | `br: <action> failed (<status>)`                  | 1 (brightness in `work` still applied) |
| Unknown subcommand                          | usage text                                        | 2    |

## Testing Strategy

- **Automated (`make test`):** pure unit checks — `parseBindings` maps
  `work = cmd+shift+0`, `away = cmd+shift+9`, `sleep = cmd+shift+8` to the right
  `(keyCode, modifiers, action)`; `parseArgs`/command parsing accepts
  `work`/`away`/`sleep`/`awake on|off|status` and rejects junk with exit 2. The
  `caffeinate`/`pmset` side effects are **not** unit-tested (they change real
  power state).
- **Implementation step 1 (manual, gated):** verify `pmset displaysleepnow` and
  `pmset sleepnow` root requirement (the only design unknown).
- **Manual acceptance:** `br work` → `pmset -g assertions` shows our
  `PreventUserIdleSystemSleep`, brightness 100%; leaving it idle → screen off after
  the OS timer while the system stays awake. `br away` → screen off immediately,
  assertion still held; input wakes the screen. `br awake off` → assertion gone.
  `br sleep` → Mac sleeps. Same three via the hotkeys ⌘⇧0/9/8.

## Known Caveats (documented in README)

- Quit/remove **Amphetamine** — while it holds `PreventUserIdleDisplaySleep` the
  screen won't turn off, defeating `work`/`away`.
- `away` uses true display sleep; a stray keypress/mouse move wakes the screen.
- Keep-awake is session-scoped: a reboot returns to normal mode.
- `sleep` (⌘⇧8) sleeps immediately with no confirmation — it is a deliberate hotkey,
  bound only if the user adds it.
