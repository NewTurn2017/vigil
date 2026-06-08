# `br` — Built-in Display Brightness Toggle

**Date:** 2026-06-08
**Status:** Approved design
**Platform:** macOS (Apple Silicon verified on macOS 26.5.1, arm64), Swift 6.x

## Summary

`br` is a single native Swift CLI binary that instantly controls the built-in
display backlight. Its headline use case is a one-key **blackout toggle**: press
once to drop brightness to 0%, press again to restore it to 100%. It also
accepts an explicit percentage and `on`/`off` aliases.

## Goals

- Instantly set the built-in display brightness to 0% and back to 100%.
- Short, ergonomic command (`br`) suitable for frequent use and hotkey binding.
- Self-contained native binary with no runtime dependencies.
- No special permissions (no Accessibility / Screen Recording prompts).

## Non-Goals (YAGNI)

- External / DDC monitor control (built-in display only).
- Display sleep / power-off (this is a *brightness* tool; the panel stays awake).
- Persisting or restoring the pre-blackout brightness (toggle restores to a flat
  100%, per the agreed behavior).
- Menu-bar widget or bundled global hotkey (user wires up their own trigger).
- Decimal percentages (integer `0`–`100` only).

## CLI Interface

| Invocation   | Action                                            |
|--------------|---------------------------------------------------|
| `br`         | Toggle: if lit (> 1%) → 0%, else → 100%           |
| `br on`      | Set 100% (alias for `br 100`)                     |
| `br off`     | Set 0% (alias for `br 0`)                         |
| `br <N>`     | Set to integer `N` percent, where `0 ≤ N ≤ 100`   |
| `br status`  | Print current brightness as an integer percent    |
| `br -h`, `br --help` | Print usage                               |

**Exit codes**

- `0` — success
- `1` — runtime error (no built-in display found, or DisplayServices API failure,
  or framework load failure)
- `2` — usage error (unknown command, non-integer argument, percent out of range)

Errors print a concise message to **stderr**. `status` prints to **stdout**.

## Behavior Details

- **Toggle threshold:** ε = 0.01. Current brightness > 0.01 counts as "lit" and
  toggles to 0.0; otherwise toggles to 1.0.
- **Percent mapping:** brightness float `0.0`–`1.0` ↔ integer percent `0`–`100`
  via `value = N / 100.0`; `status` prints `round(value * 100)`.
- **`on`/`off`** are exact aliases for `100`/`0`.

## Implementation

Single source file: `Sources/main.swift` (~80 lines), built with `swiftc`.

**Finding the built-in display** (verified-correct approach — `CGMainDisplayID()`
returns the wrong display when virtual displays are present):

1. `CGGetActiveDisplayList` to enumerate active `CGDirectDisplayID`s.
2. Select the first display where `CGDisplayIsBuiltin(id) == 1`.
3. If none found → error, exit 1.

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

**Control flow**

```
parse args -> determine intent (toggle | set N | status | help)
load DisplayServices (dlopen/dlsym)        // on failure: stderr, exit 1
find built-in display id                   // on failure: stderr, exit 1
case status:  get -> print round(v*100)
case set N:   set N/100.0                   // on rc!=0: stderr, exit 1
case toggle:  get -> set (v > eps ? 0 : 1)  // on rc!=0: stderr, exit 1
```

## Build & Install

Plain `swiftc` + `Makefile` (no SPM, no Xcode project):

- `make` → `swiftc -O -o br Sources/main.swift`
- `make install` → `install -m 755 br "$(PREFIX)/bin/br"` (default `PREFIX=/usr/local`;
  may require `sudo`). Document `PREFIX=~/.local` as a no-sudo alternative.
- `make clean` → remove the built binary.
- `make test` → non-destructive check: read current brightness, set it to the
  same value, assert rc=0 and that the readback matches; also run `br status`.

## Project Layout

```
Screenbrightness/
  Sources/main.swift
  Makefile
  README.md
  docs/superpowers/specs/2026-06-08-br-brightness-toggle-design.md
```

## Error Handling

| Condition                         | Output (stderr)                         | Exit |
|-----------------------------------|-----------------------------------------|------|
| DisplayServices dlopen/dlsym fail | `br: DisplayServices unavailable`       | 1    |
| No built-in display               | `br: no built-in display found`         | 1    |
| Get/Set returns non-zero          | `br: failed to <get/set> brightness`    | 1    |
| Unknown command                   | usage text                              | 2    |
| Non-integer / out-of-range percent| `br: brightness must be an integer 0-100` | 2  |

## Testing Strategy

- **Automated (`make test`):** non-destructive get → set-same → assert success +
  readback; exercises the full framework-load + display-resolution + get/set path
  without visibly changing the screen.
- **Manual:** `br status` shows current %; `br off` blacks the screen; `br on`
  restores to 100%; `br` (no args) flips between them; `br 50` lands at ~50%;
  `br 150` and `br abc` print a usage error and exit 2.

## Known Caveats (documented in README)

- macOS auto-brightness (ambient light sensor) may slowly re-raise brightness
  after `br off`; disabling it is out of scope.
- Built-in Apple panels retain a faint glow at 0% (not pure black) — expected.
- Installing to `/usr/local/bin` may require `sudo`; `~/.local/bin` avoids it.
