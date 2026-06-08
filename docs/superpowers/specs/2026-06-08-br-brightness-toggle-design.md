# `br` — Built-in Display Brightness Toggle + Hotkey Agent

**Date:** 2026-06-08
**Status:** Approved design
**Platform:** macOS (Apple Silicon verified on macOS 26.5.1, arm64), Swift 6.x

## Summary

`br` is a single native Swift binary with two modes:

1. **CLI mode** — instantly controls the built-in display backlight: a one-key
   **blackout toggle** (press once → 0%, press again → 100%), plus explicit
   percentage and `on`/`off` aliases.
2. **Agent mode** (`br agent`) — a background process that registers a global
   hotkey and runs the same toggle. This solves the core problem: once the screen
   is black you cannot see a terminal to type `br on`, so a global hotkey restores
   it. The Mac stays fully awake at 0% brightness, so the hotkey always fires.

It also has an **opt-in clamshell coupling**: when set up (`make sleep-setup`),
brightness 0% additionally runs `pmset disablesleep 1` so the Mac stays awake with
the lid closed, and 100% runs `pmset disablesleep 0` to restore normal sleep. The
privileged `pmset` runs via a tightly-scoped passwordless sudoers rule so it works
from the hotkey even when the screen is black.

## Goals

- Instantly set the built-in display brightness to 0% and back to 100%.
- Short, ergonomic command (`br`) suitable for frequent use.
- A global hotkey that toggles brightness even when the screen is black, with no
  third-party dependencies and no Accessibility permission prompt.
- Self-contained native binary, no runtime dependencies.

## Non-Goals (YAGNI)

- External / DDC monitor control (built-in display only).
- Putting the display to sleep / powering off the panel (brightness 0 keeps the
  panel awake; sleep is only ever *disabled* via the opt-in clamshell coupling).
- Persisting or restoring the pre-blackout brightness (toggle restores to a flat
  100%, per the agreed behavior).
- Menu-bar UI / Dock icon (the agent is headless — `.accessory` activation policy).
- Decimal percentages (integer `0`–`100` only).
- Hotkey actions beyond `on` / `off` / `toggle` (e.g. a key bound to set 37%).

## CLI Interface

| Invocation   | Action                                            |
|--------------|---------------------------------------------------|
| `br`         | Toggle: if lit (> 1%) → 0%, else → 100%           |
| `br on`      | Set 100% (alias for `br 100`)                     |
| `br off`     | Set 0% (alias for `br 0`)                         |
| `br <N>`     | Set to integer `N` percent, where `0 ≤ N ≤ 100`   |
| `br status`  | Print current brightness as an integer percent    |
| `br agent`   | Run the background hotkey agent (foreground; normally launched by launchd) |
| `br -h`, `br --help` | Print usage                               |

**Exit codes**

- `0` — success
- `1` — runtime error (no built-in display found, DisplayServices API failure,
  framework load failure, or hotkey registration failure in agent mode)
- `2` — usage error (unknown command, non-integer argument, percent out of range)

Errors print a concise message to **stderr**. `status` prints to **stdout**.

## Behavior Details

- **Toggle threshold:** ε = 0.01. Current brightness > 0.01 counts as "lit" and
  toggles to 0.0; otherwise toggles to 1.0.
- **Percent mapping:** brightness float `0.0`–`1.0` ↔ integer percent `0`–`100`
  via `value = N / 100.0`; `status` prints `Int(round(value * 100))`.
- **`on`/`off`** are exact aliases for `100`/`0`.

## Architecture

One binary, three focused source files plus an entry dispatcher:

| File | Responsibility |
|------|----------------|
| `Sources/Brightness.swift` | Resolve the built-in display; load DisplayServices; `getBrightness` / `setBrightness` / `toggle` |
| `Sources/CLI.swift` | Parse args; run `toggle` / `on` / `off` / `<N>` / `status` / help; map results to exit codes |
| `Sources/Agent.swift` | Parse the hotkey config; register the Carbon global hotkey; run the accessory run loop; act on press |
| `Sources/Sleep.swift` | `sleepIntent` (pure decision), `setSleepDisabled` (`sudo -n pmset`), `applySleepCoupling` (opt-in, gated on the sudoers file) |
| `Sources/main.swift` | Top-level entry: dispatch to `runAgent()` if first arg is `agent`, else `runCLI()` |

(Swift permits top-level statements only in `main.swift`; the other files expose
functions/types.)

### Brightness core (`Brightness.swift`)

**Finding the built-in display** (verified-correct approach — `CGMainDisplayID()`
returns the wrong display when virtual displays are present):

1. `CGGetActiveDisplayList` to enumerate active `CGDirectDisplayID`s.
2. Select the first display where `CGDisplayIsBuiltin(id) == 1`.
3. If none found → throw → caller prints error, exit 1.

**Brightness get/set via the DisplayServices private framework**, loaded at
runtime with `dlopen`/`dlsym` (avoids fragile build-time linking against a
private framework path):

- `dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)`
- `dlsym` → `DisplayServicesGetBrightness` as
  `@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32`
- `dlsym` → `DisplayServicesSetBrightness` as
  `@convention(c) (UInt32, Float) -> Int32`
- Both return `0` on success (verified on macOS 26.5.1).

**Verification already performed on target hardware:** built-in display resolved
to id=1 (`CGDisplayIsBuiltin==1`, `DisplayServicesCanChangeBrightness==1`),
`GetBrightness` returned rc=0 with value 0.346, and `SetBrightness` returned rc=0
with a correct readback. No permission prompts were triggered.

### CLI mode control flow (`CLI.swift`)

```
parse args -> intent (toggle | set N | status | help)
load DisplayServices + find built-in display   // on failure: stderr, exit 1
case status:  get -> print Int(round(v*100))
case set N:   set N/100.0                        // on rc!=0: stderr, exit 1
case toggle:  get -> set (v > eps ? 0 : 1)       // on rc!=0: stderr, exit 1
```

### Agent mode (`Agent.swift`)

- **Bindings:** the agent registers one or more hotkeys, each bound to an action
  (`on` = 100%, `off` = 0%, `toggle`). A fixed Carbon hotkey id per action
  (on=1, off=2, toggle=3) lets a single stateless event handler tell presses apart
  via `GetEventParameter(kEventParamDirectObject, typeEventHotKeyID)`.
- **Hotkey registration:** Carbon `RegisterEventHotKey` on
  `GetApplicationEventTarget()` per binding, with one `InstallEventHandler` for
  `kEventHotKeyPressed`. The handler is a non-capturing closure (convertible to
  `EventHandlerUPP`) that reads the pressed hotkey's id and performs the matching
  action. `RegisterEventHotKey` requires **no Accessibility permission**.
- **Run loop:** `NSApplication.shared`, `setActivationPolicy(.accessory)` (headless,
  no Dock icon), then `app.run()`. Running inside the user's Aqua GUI session (via
  the LaunchAgent) gives the window-server connection the hotkey needs.
- **Default (no config):** a single `toggle` bound to `⌃⌥⌘B` → Carbon
  `keyCode = 11` (kVK_ANSI_B), `modifiers = controlKey | optionKey | cmdKey = 6400`.
- **Hotkey config:** optional `~/.config/br/hotkey.conf`, one `action = combo` per
  line where action is `on` / `off` / `toggle` (a bare line with no `=` is treated
  as a toggle combo). Each combo is parsed into modifiers + key via a token map
  (`ctrl`/`control`, `opt`/`option`/`alt`, `cmd`/`command`/`super`, `shift`, plus a
  key from a keycode table covering `a`–`z`, `0`–`9`, `f1`–`f20`, `space`,
  `escape`, `return`, `tab`). Blank lines and `#` comments are ignored. Unparseable
  lines are skipped with a stderr warning; an empty/missing config falls back to the
  default `⌃⌥⌘B` toggle. Example: `on = cmd+shift+0` and `off = cmd+shift+9`.
- **Registration failure** (e.g. a combo is already taken): log a clear message per
  binding; the agent exits 1 only if **no** hotkey could be registered. launchd's
  default respawn throttle (~10s) prevents a tight crash loop.

### Clamshell / sleep coupling (`Sleep.swift`)

- **Decision (pure):** `sleepIntent(forBrightness:)` → `.disable` at ≤ 0.001,
  `.enable` at ≥ 0.999, else `.leave`. So brightness endpoints 0% / 100% drive
  clamshell; intermediate values leave sleep untouched.
- **Application:** both CLI (`set`/`toggle`) and the agent (`performAction`) call
  `applySleepCoupling(forBrightness:)` after changing brightness. It is **opt-in** —
  gated on the existence of `/etc/sudoers.d/br`, so without setup `br` never calls
  `pmset` and prints no warning (brightness behaves exactly as before).
- **Privileged call:** `setSleepDisabled(_:)` runs
  `sudo -n /usr/bin/pmset -c disablesleep <1|0>`. `-n` is non-interactive; with the
  NOPASSWD sudoers rule it succeeds with no tty (works from the LaunchAgent). On
  failure it prints `br: sleep control failed — run: sudo make sleep-setup` and
  returns false; the brightness change still succeeds.
- **Sudoers rule** (installed by `make sleep-setup`, validated with `visudo -cf`,
  mode 0440 root:wheel at `/etc/sudoers.d/br`): grants the user NOPASSWD for **only**
  `pmset -c disablesleep 0` and `pmset -c disablesleep 1` — nothing else.

## Build & Install

Plain `swiftc` + `Makefile` (no SPM, no Xcode project):

- `make` → `swiftc -O -o br Sources/Brightness.swift Sources/CLI.swift Sources/Agent.swift Sources/Sleep.swift Sources/main.swift`
- `make install` → `install -m 755 br "$(PREFIX)/bin/br"` (default `PREFIX=/usr/local`;
  may require `sudo`). Document `PREFIX=$HOME/.local` as a no-sudo alternative.
- `make hotkey-install` → render `com.genie.br.plist` from a template with the
  absolute installed binary path (`$(PREFIX)/bin/br agent`) into
  `~/Library/LaunchAgents/`, then
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.genie.br.plist` and
  `launchctl kickstart -k gui/$(id -u)/com.genie.br`.
- `make hotkey-uninstall` → `launchctl bootout gui/$(id -u)/com.genie.br` (ignore if
  not loaded) and remove the plist.
- `make sleep-setup` → render `sudoers/br.sudoers.template` for the invoking user
  (`$${SUDO_USER:-$$(id -un)}`), `sudo visudo -cf` to validate, then
  `sudo install -m 0440 -o root -g wheel` to `/etc/sudoers.d/br`. Run as the normal
  user (recipe sudoes internally; one password prompt).
- `make sleep-teardown` → `sudo rm -f /etc/sudoers.d/br`.
- `make clean` → remove the built binary.
- `make test` → non-destructive check (see Testing Strategy).

### LaunchAgent plist (`com.genie.br`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.genie.br</string>
  <key>ProgramArguments</key> <array>
                                <string>__BR_PATH__</string>
                                <string>agent</string>
                              </array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardErrorPath</key><string>__LOG_PATH__</string>
  <key>StandardOutPath</key>  <string>__LOG_PATH__</string>
</dict>
</plist>
```

`__BR_PATH__` → `$(PREFIX)/bin/br`; `__LOG_PATH__` → `$HOME/Library/Logs/br-agent.log`.

## Project Layout

```
Screenbrightness/
  Sources/Brightness.swift
  Sources/CLI.swift
  Sources/Agent.swift
  Sources/Sleep.swift
  Sources/main.swift
  launchd/com.genie.br.plist.template
  sudoers/br.sudoers.template
  Makefile
  README.md
  LICENSE
  docs/superpowers/specs/2026-06-08-br-brightness-toggle-design.md
```

## Error Handling

| Condition                          | Output (stderr)                          | Exit |
|------------------------------------|------------------------------------------|------|
| DisplayServices dlopen/dlsym fail  | `br: DisplayServices unavailable`        | 1    |
| No built-in display                | `br: no built-in display found`          | 1    |
| Get/Set returns non-zero           | `br: failed to <get/set> brightness`     | 1    |
| Hotkey registration fails (agent)  | `br: could not register hotkey <combo>`  | 1    |
| Unknown command                    | usage text                               | 2    |
| Non-integer / out-of-range percent | `br: brightness must be an integer 0-100`| 2    |
| `pmset` fails despite sudoers rule | `br: sleep control failed — run: sudo make sleep-setup` | 0 (brightness still set) |

Agent mode also logs non-fatal warnings (e.g. bad config line → using default) to
stderr, which the LaunchAgent routes to `~/Library/Logs/br-agent.log`.

## Testing Strategy

- **Automated (`make test`):** non-destructive get → set-same → assert success +
  readback; exercises framework-load + display-resolution + get/set without
  visibly changing the screen. Also asserts arg parsing: `br 150` and `br abc`
  exit 2; `br status` prints a `0`–`100` integer.
- **Hotkey-config unit check:** parsing `ctrl+opt+cmd+b` yields keyCode 11,
  modifiers 6400; `parseBindings` maps `on = cmd+shift+0` / `off = cmd+shift+9` to
  the right `(keyCode, modifiers, action)`; comments/blank/unknown-action/bad-combo
  lines are skipped; a bare line becomes a toggle binding.
- **Sleep-coupling unit check:** `sleepIntent(forBrightness:)` → `.disable` at 0.0,
  `.enable` at 1.0, `.leave` at mid values (the `pmset` side effect itself is not
  unit-tested — it needs root and changes system state).
- **Manual:** `br status` shows current %; `br off` blacks the screen; the hotkey
  restores it to 100%; pressing again blacks it; `br 50` lands at ~50%. After
  `make hotkey-install`, the hotkey works in any app and survives logout/login.
  After `make sleep-setup`: `br off` → `pmset -g` shows `SleepDisabled 1`, `br on`
  → `0` (verified via CLI and via the hotkey/agent).

## Known Caveats (documented in README)

- macOS auto-brightness (ambient light sensor) may slowly re-raise brightness
  after `br off`; disabling it is out of scope.
- Built-in Apple panels retain a faint glow at 0% (not pure black) — expected.
- Installing to `/usr/local/bin` may require `sudo`; `$HOME/.local/bin` avoids it.
- The agent must run in the user's GUI (Aqua) session for the hotkey to register;
  the provided LaunchAgent ensures this.
- Clamshell coupling keeps the Mac awake with the lid closed (`disablesleep 1`); on
  battery this will keep draining, and `br on` (or `make sleep-teardown`) is needed
  to restore normal sleep. The sudoers rule grants passwordless `pmset` for only the
  two `disablesleep 0|1` commands.
