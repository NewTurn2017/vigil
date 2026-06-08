# `br` Brightness Toggle + Hotkey Agent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `br`, a native macOS CLI that instantly toggles the built-in display brightness between 0% and 100% (plus `on`/`off`/`<N>`/`status`), with a self-contained global-hotkey agent so brightness can be restored when the screen is black.

**Architecture:** One Swift binary, four source files. `Brightness.swift` resolves the built-in display and drives the DisplayServices private framework (loaded via `dlopen`/`dlsym`). `CLI.swift` parses args and maps commands to exit codes. `Agent.swift` parses a hotkey config and registers a Carbon global hotkey (no Accessibility permission) running in a headless `NSApplication` loop. `main.swift` is the entry point. A `Makefile` builds with `swiftc` (no SPM/Xcode) and installs a LaunchAgent.

**Tech Stack:** Swift 6.x, `swiftc`, CoreGraphics, DisplayServices (private), Carbon.HIToolbox, AppKit, launchd. Tests via a hand-rolled assertion harness compiled with `swiftc` (no XCTest).

**Verified up front (on the target Mac, macOS 26.5.1 / arm64):** the built-in display is found via `CGGetActiveDisplayList` + `CGDisplayIsBuiltin` (not `CGMainDisplayID`); `DisplayServicesGetBrightness`/`SetBrightness` return `0` and read/write correctly; no permission prompts appear.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Sources/Brightness.swift` | `BrightnessError`, DisplayServices loader, `BuiltinDisplay` (resolve display, `getBrightness`/`setBrightness`/`toggle`) |
| `Sources/CLI.swift` | `Command` enum, `parsePercent`, `parseArgs`, `usageText`, `errPrint`, `withDisplay`, `runCLI` |
| `Sources/Agent.swift` | `Hotkey`, modifier constants, `keyCode(for:)`, `parseHotkey`, `loadHotkey`, `runAgent` |
| `Sources/main.swift` | Top-level entry: `exit(runCLI(...))` |
| `Tests/main.swift` | Assertion harness + unit/integration checks (compiled into `br-test`) |
| `launchd/com.genie.br.plist.template` | LaunchAgent template (`__BR_PATH__`, `__LOG_PATH__` placeholders) |
| `Makefile` | `all`/`test`/`install`/`hotkey-install`/`hotkey-uninstall`/`clean` |
| `README.md` | Usage, install, hotkey config, caveats |

`Tests/main.swift` runs top-level `check(...)` statements in order, then prints a summary and `exit`s nonzero on any failure. Each task appends its checks **above** the summary block.

---

## Task 1: Test harness + `parsePercent` (TDD)

**Files:**
- Create: `Tests/main.swift`
- Create: `Sources/CLI.swift`
- Create: `Makefile`

- [ ] **Step 1: Write the failing test** — create `Tests/main.swift`:

```swift
import Foundation

var testsRun = 0
var testsFailed = 0

func check(_ cond: Bool, _ msg: String) {
    testsRun += 1
    if cond { print("ok   - \(msg)") }
    else { testsFailed += 1; print("FAIL - \(msg)") }
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    check(a == b, "\(msg) (got \(a), want \(b))")
}

// === parsePercent ===
check(parsePercent("80") == 80, "parsePercent 80")
check(parsePercent("0") == 0, "parsePercent 0")
check(parsePercent("100") == 100, "parsePercent 100")
check(parsePercent("150") == nil, "parsePercent 150 -> nil")
check(parsePercent("-5") == nil, "parsePercent -5 -> nil")
check(parsePercent("abc") == nil, "parsePercent abc -> nil")
check(parsePercent("12.5") == nil, "parsePercent 12.5 -> nil")

// === SUMMARY (keep last) ===
print("\n\(testsRun - testsFailed)/\(testsRun) passed")
exit(testsFailed == 0 ? 0 : 1)
```

- [ ] **Step 2: Create the Makefile** so `make test` works:

```make
PREFIX ?= /usr/local
BIN := br
LIB := Sources/Brightness.swift Sources/CLI.swift Sources/Agent.swift
PLIST := com.genie.br
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/$(PLIST).plist
LOG := $(HOME)/Library/Logs/br-agent.log
DOMAIN := gui/$(shell id -u)

.PHONY: all test install uninstall hotkey-install hotkey-uninstall clean

all: $(BIN)

$(BIN): $(LIB) Sources/main.swift
	swiftc -O -o $(BIN) $(LIB) Sources/main.swift

br-test: $(LIB) Tests/main.swift
	swiftc -o br-test $(LIB) Tests/main.swift

test: br-test
	./br-test

install: $(BIN)
	install -d "$(PREFIX)/bin"
	install -m 755 $(BIN) "$(PREFIX)/bin/$(BIN)"
	@echo "installed $(PREFIX)/bin/$(BIN)"

uninstall:
	rm -f "$(PREFIX)/bin/$(BIN)"

hotkey-install:
	@test -x "$(PREFIX)/bin/$(BIN)" || { echo "run 'make install' (maybe with sudo, or PREFIX=\$$HOME/.local) first"; exit 1; }
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed -e 's#__BR_PATH__#$(PREFIX)/bin/$(BIN)#' -e 's#__LOG_PATH__#$(LOG)#' \
		launchd/$(PLIST).plist.template > "$(LAUNCH_AGENT)"
	launchctl bootout $(DOMAIN)/$(PLIST) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) "$(LAUNCH_AGENT)"
	launchctl kickstart -k $(DOMAIN)/$(PLIST)
	@echo "hotkey agent loaded (default key: ctrl-opt-cmd-B). Logs: $(LOG)"

hotkey-uninstall:
	launchctl bootout $(DOMAIN)/$(PLIST) 2>/dev/null || true
	rm -f "$(LAUNCH_AGENT)"
	@echo "hotkey agent unloaded"

clean:
	rm -f $(BIN) br-test
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `make test`
Expected: swiftc compile error — `cannot find 'parsePercent' in scope` (also `Sources/Brightness.swift`/`Sources/Agent.swift` don't exist yet → "no such file"). This confirms the test references unimplemented code. (To see only the parsePercent failure in isolation you may temporarily run `swiftc -o /tmp/t Sources/CLI.swift Tests/main.swift` after Step 4 creates CLI.swift; the canonical gate is `make test`.)

- [ ] **Step 4: Write the minimal implementation** — create `Sources/CLI.swift`:

```swift
import Foundation

/// Parse a brightness percentage argument. Returns 0...100 on success, else nil.
func parsePercent(_ s: String) -> Int? {
    guard let n = Int(s), (0...100).contains(n) else { return nil }
    return n
}
```

- [ ] **Step 5: Create placeholder source files** so the `LIB` compile unit is complete. Create `Sources/Brightness.swift`:

```swift
import CoreGraphics
import Darwin
```

Create `Sources/Agent.swift`:

```swift
import Foundation
```

(These get real content in later tasks; empty-but-importing files compile cleanly.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `make test`
Expected: all `parsePercent` lines print `ok`, final line `7/7 passed`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add Sources/ Tests/ Makefile
git commit -m "feat: parsePercent + test harness + Makefile"
```

---

## Task 2: `Command` + `parseArgs` (TDD)

**Files:**
- Modify: `Sources/CLI.swift`
- Modify: `Tests/main.swift`

- [ ] **Step 1: Write the failing test** — in `Tests/main.swift`, insert these lines immediately above the `=== SUMMARY` block:

```swift
// === parseArgs ===
func isUsageError(_ c: Command) -> Bool { if case .usageError = c { return true }; return false }
checkEqual(parseArgs([]), .toggle, "no args -> toggle")
checkEqual(parseArgs(["on"]), .set(100), "on -> set 100")
checkEqual(parseArgs(["off"]), .set(0), "off -> set 0")
checkEqual(parseArgs(["50"]), .set(50), "50 -> set 50")
checkEqual(parseArgs(["status"]), .status, "status -> status")
checkEqual(parseArgs(["agent"]), .agent, "agent -> agent")
checkEqual(parseArgs(["-h"]), .help, "-h -> help")
checkEqual(parseArgs(["--help"]), .help, "--help -> help")
check(isUsageError(parseArgs(["abc"])), "abc -> usageError")
check(isUsageError(parseArgs(["150"])), "150 -> usageError")
check(isUsageError(parseArgs(["50", "60"])), "extra args -> usageError")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: compile error `cannot find 'parseArgs' in scope` / `cannot find type 'Command' in scope`.

- [ ] **Step 3: Write the minimal implementation** — append to `Sources/CLI.swift`:

```swift
/// A parsed command-line intent.
enum Command: Equatable {
    case toggle
    case set(Int)            // 0...100
    case status
    case help
    case agent
    case usageError(String)
}

/// Parse argv (excluding program name) into a Command.
func parseArgs(_ args: [String]) -> Command {
    guard let first = args.first else { return .toggle }
    if args.count > 1 { return .usageError("too many arguments") }
    switch first {
    case "on":           return .set(100)
    case "off":          return .set(0)
    case "status":       return .status
    case "agent":        return .agent
    case "-h", "--help": return .help
    default:
        if let n = parsePercent(first) { return .set(n) }
        return .usageError("unknown command or invalid percentage: \(first)")
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: all `ok`, summary `18/18 passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLI.swift Tests/main.swift
git commit -m "feat: Command enum + parseArgs"
```

---

## Task 3: Brightness core (display resolution + get/set/toggle)

**Files:**
- Modify: `Sources/Brightness.swift`
- Modify: `Tests/main.swift`

This unit touches real hardware, so the check is a **non-destructive integration test**: read brightness, set it back to the same value, confirm success and that the value is unchanged. Nothing visible happens.

- [ ] **Step 1: Write the failing test** — in `Tests/main.swift`, insert above the `=== SUMMARY` block:

```swift
// === BuiltinDisplay (non-destructive integration) ===
do {
    let d = try BuiltinDisplay()
    let v = try d.getBrightness()
    check(v >= 0 && v <= 1, "getBrightness in 0...1 (got \(v))")
    try d.setBrightness(v)                 // set to current value: no visible change
    let v2 = try d.getBrightness()
    check(abs(v2 - v) < 0.05, "setBrightness(same) preserves value (\(v) -> \(v2))")
} catch {
    check(false, "brightness round-trip threw: \(error)")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: compile error `cannot find 'BuiltinDisplay' in scope`.

- [ ] **Step 3: Write the minimal implementation** — replace the contents of `Sources/Brightness.swift` with:

```swift
import CoreGraphics
import Darwin

enum BrightnessError: Error, CustomStringConvertible {
    case frameworkUnavailable
    case noBuiltinDisplay
    case getFailed
    case setFailed
    var description: String {
        switch self {
        case .frameworkUnavailable: return "DisplayServices unavailable"
        case .noBuiltinDisplay:     return "no built-in display found"
        case .getFailed:            return "failed to get brightness"
        case .setFailed:            return "failed to set brightness"
        }
    }
}

private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
private typealias SetBrightnessFn = @convention(c) (UInt32, Float) -> Int32

/// Lazily-loaded function pointers from the DisplayServices private framework.
private struct DisplayServices {
    let get: GetBrightnessFn
    let set: SetBrightnessFn

    static func load() -> DisplayServices? {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return DisplayServices(
            get: unsafeBitCast(g, to: GetBrightnessFn.self),
            set: unsafeBitCast(s, to: SetBrightnessFn.self)
        )
    }
}

/// The built-in display, with brightness controls.
struct BuiltinDisplay {
    private let ds: DisplayServices
    let id: CGDirectDisplayID

    init() throws {
        guard let ds = DisplayServices.load() else { throw BrightnessError.frameworkUnavailable }
        self.ds = ds
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        guard let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
        else { throw BrightnessError.noBuiltinDisplay }
        self.id = builtin
    }

    func getBrightness() throws -> Float {
        var value: Float = 0
        guard ds.get(id, &value) == 0 else { throw BrightnessError.getFailed }
        return value
    }

    func setBrightness(_ value: Float) throws {
        let clamped = max(0, min(1, value))
        guard ds.set(id, clamped) == 0 else { throw BrightnessError.setFailed }
    }

    /// If lit (> eps), go dark; otherwise go to 100%.
    func toggle() throws {
        let eps: Float = 0.01
        let current = try getBrightness()
        try setBrightness(current > eps ? 0.0 : 1.0)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: `ok - getBrightness in 0...1`, `ok - setBrightness(same) preserves value`, summary `20/20 passed`, exit 0. The screen does **not** change.

- [ ] **Step 5: Commit**

```bash
git add Sources/Brightness.swift Tests/main.swift
git commit -m "feat: BuiltinDisplay brightness core via DisplayServices"
```

---

## Task 4: CLI runner + entry point

**Files:**
- Modify: `Sources/CLI.swift`
- Create: `Sources/main.swift`

`runAgent()` is referenced here but implemented in Task 6; add a temporary stub so this task compiles, then replace it in Task 6.

- [ ] **Step 1: Append the runner to `Sources/CLI.swift`:**

```swift
/// Print a line to stderr.
func errPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func usageText() -> String {
    return """
    br — built-in display brightness toggle

    usage:
      br            toggle 0% <-> 100%
      br on         set 100%
      br off        set 0%
      br <0-100>    set that percent
      br status     print current percent
      br agent      run the global-hotkey agent (usually launched by launchd)
      br -h         show this help
    """
}

/// Resolve the built-in display, run `body`, map any error to exit code 1.
func withDisplay(_ body: (BuiltinDisplay) throws -> Void) -> Int32 {
    do {
        try body(BuiltinDisplay())
        return 0
    } catch {
        errPrint("br: \(error)")
        return 1
    }
}

/// Run CLI mode; returns the process exit code.
func runCLI(_ args: [String]) -> Int32 {
    switch parseArgs(args) {
    case .help:
        print(usageText()); return 0
    case .usageError(let msg):
        errPrint("br: \(msg)"); errPrint(usageText()); return 2
    case .agent:
        return runAgent()
    case .status:
        return withDisplay { d in print(Int((try d.getBrightness() * 100).rounded())) }
    case .set(let n):
        return withDisplay { d in try d.setBrightness(Float(n) / 100.0) }
    case .toggle:
        return withDisplay { d in try d.toggle() }
    }
}
```

- [ ] **Step 2: Add a temporary `runAgent` stub** at the end of `Sources/Agent.swift` (replaces the lone `import Foundation`; full implementation lands in Task 6):

```swift
import Foundation

// TEMPORARY stub — replaced by the real agent in Task 6.
func runAgent() -> Int32 {
    errPrint("br: agent not implemented yet")
    return 1
}
```

- [ ] **Step 3: Create the entry point** `Sources/main.swift`:

```swift
import Foundation

exit(runCLI(Array(CommandLine.arguments.dropFirst())))
```

- [ ] **Step 4: Build and verify the CLI end-to-end (non-destructive)**

Run:
```bash
make
echo "--- help ---";   ./br -h
echo "--- status ---"; ./br status
echo "--- bad ---";    ./br abc; echo "exit=$?"
echo "--- extra ---";  ./br 50 60; echo "exit=$?"
echo "--- range ---";  ./br 150; echo "exit=$?"
```
Expected: help text prints (exit 0); `status` prints an integer 0–100; `./br abc` prints `br: unknown command...` + usage to stderr and `exit=2`; extra args → `exit=2`; `./br 150` → `exit=2`. (Skip running bare `./br`/`./br off` here to avoid blacking the screen before the hotkey exists — that is verified in Task 8.)

- [ ] **Step 5: Run the unit/integration tests**

Run: `make test`
Expected: still `20/20 passed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLI.swift Sources/Agent.swift Sources/main.swift
git commit -m "feat: CLI runner, usage, exit codes, entry point (agent stubbed)"
```

---

## Task 5: Hotkey parsing (TDD)

**Files:**
- Modify: `Sources/Agent.swift`
- Modify: `Tests/main.swift`

- [ ] **Step 1: Write the failing test** — in `Tests/main.swift`, insert above the `=== SUMMARY` block:

```swift
// === hotkey parsing ===
check(parseHotkey("ctrl+opt+cmd+b") == Hotkey(keyCode: 11, modifiers: 6400), "parse ctrl+opt+cmd+b")
check(parseHotkey("cmd+shift+l") == Hotkey(keyCode: 37, modifiers: 768), "parse cmd+shift+l")
check(parseHotkey("f13") == Hotkey(keyCode: 105, modifiers: 0), "parse f13 (no mods)")
check(parseHotkey("CMD-B") == Hotkey(keyCode: 11, modifiers: 256), "parse CMD-B (case/dash)")
check(parseHotkey("") == nil, "empty -> nil")
check(parseHotkey("cmd+shift") == nil, "mods only -> nil")
check(parseHotkey("cmd+zzz") == nil, "unknown key -> nil")
check(defaultHotkey == Hotkey(keyCode: 11, modifiers: 6400), "default is ctrl-opt-cmd-B")
```

(`6400` = ctrl `4096` + opt `2048` + cmd `256`; `768` = cmd `256` + shift `512`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: compile error `cannot find 'parseHotkey'` / `cannot find type 'Hotkey'` / `cannot find 'defaultHotkey'`.

- [ ] **Step 3: Write the minimal implementation** — replace the temporary stub block in `Sources/Agent.swift` so the file begins with the parsing code, keeping the `runAgent` stub at the bottom for now:

```swift
import Foundation

struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

// Carbon modifier masks (cmdKey/shiftKey/optionKey/controlKey).
let kBRcmd: UInt32   = 256
let kBRshift: UInt32 = 512
let kBRopt: UInt32   = 2048
let kBRctrl: UInt32  = 4096

let defaultHotkey = Hotkey(keyCode: 11, modifiers: kBRctrl | kBRopt | kBRcmd) // ctrl-opt-cmd-B

/// Map a key token (letter, digit, named key, f-key) to a Carbon virtual key code.
func keyCode(for token: String) -> UInt32? {
    let letters: [String: UInt32] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
        "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
    let digits: [String: UInt32] = [
        "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29]
    let named: [String: UInt32] = [
        "space":49,"escape":53,"esc":53,"return":36,"tab":48,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,
        "f9":101,"f10":109,"f11":103,"f12":111,"f13":105,"f14":107,"f15":113,
        "f16":106,"f17":64,"f18":79,"f19":80,"f20":90]
    let t = token.lowercased()
    return letters[t] ?? digits[t] ?? named[t]
}

/// Parse a hotkey string like "ctrl+opt+cmd+b" (separators: + - space). nil if no key.
func parseHotkey(_ line: String) -> Hotkey? {
    let tokens = line.lowercased()
        .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
        .map(String.init)
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }
    var mods: UInt32 = 0
    var key: UInt32? = nil
    for t in tokens {
        switch t {
        case "cmd", "command", "super", "meta": mods |= kBRcmd
        case "shift":                           mods |= kBRshift
        case "opt", "option", "alt":            mods |= kBRopt
        case "ctrl", "control":                 mods |= kBRctrl
        default:
            if let k = keyCode(for: t) { key = k } else { return nil }
        }
    }
    guard let k = key else { return nil }
    return Hotkey(keyCode: k, modifiers: mods)
}

/// Load the hotkey from ~/.config/br/hotkey.conf; fall back to the default.
func loadHotkey() -> Hotkey {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/br/hotkey.conf")
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return defaultHotkey }
    let line = raw.split(separator: "\n").map(String.init)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) ?? ""
    if let hk = parseHotkey(line) { return hk }
    errPrint("br: could not parse hotkey '\(line)', using default ctrl-opt-cmd-B")
    return defaultHotkey
}

// TEMPORARY stub — replaced by the real agent in Task 6.
func runAgent() -> Int32 {
    errPrint("br: agent not implemented yet")
    return 1
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: all hotkey lines `ok`, summary `28/28 passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/Agent.swift Tests/main.swift
git commit -m "feat: hotkey config parsing (parseHotkey/keyCode/loadHotkey)"
```

---

## Task 6: Agent mode (Carbon global hotkey + run loop)

**Files:**
- Modify: `Sources/Agent.swift`

The run loop and global hotkey can't be unit-tested; this task is verified manually (foreground run + key press). Implementation replaces the stub.

- [ ] **Step 1: Replace the `runAgent` stub** at the bottom of `Sources/Agent.swift` with the real implementation, and add the two imports at the **top** of the file (just under `import Foundation`):

Add imports at the top of `Sources/Agent.swift`:

```swift
import Cocoa
import Carbon.HIToolbox
```

Replace the temporary stub block:

```swift
// TEMPORARY stub — replaced by the real agent in Task 6.
func runAgent() -> Int32 {
    errPrint("br: agent not implemented yet")
    return 1
}
```

with:

```swift
/// Run the headless global-hotkey agent. Blocks in the app run loop on success;
/// returns a nonzero exit code if the hotkey could not be registered.
func runAgent() -> Int32 {
    let hk = loadHotkey()

    // Handle hotkey-pressed events by toggling brightness.
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        try? BuiltinDisplay().toggle()   // fresh resolve each press; dlopen is cached
        return noErr
    }, 1, &spec, nil, nil)

    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x6272_746b), id: 1) // 'brtk'
    let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id,
                                     GetApplicationEventTarget(), 0, &ref)
    guard status == noErr else {
        errPrint("br: could not register hotkey (status \(status)); is the combo already in use?")
        return 1
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // headless: no Dock icon, no menu bar
    app.run()
    return 0   // not reached
}
```

- [ ] **Step 2: Build**

Run: `make`
Expected: compiles cleanly, produces `./br`.

- [ ] **Step 3: Verify the agent registers and toggles (manual)**

Run in a terminal you can see: `./br agent &`  (runs in background of the shell)
Then press **Control-Option-Command-B**.
Expected: screen blacks out. Press it again → screen returns to 100%. No permission prompt appears.
Then stop it: `kill %1` (or `pkill -f 'br agent'`).

Also verify a bad combo is reported: temporarily create the config and run in foreground:
```bash
mkdir -p ~/.config/br && echo 'cmd+space' > ~/.config/br/hotkey.conf
./br agent; echo "exit=$?"
rm -f ~/.config/br/hotkey.conf
```
Expected: `br: could not register hotkey ...` and `exit=1` (cmd+space is taken by Spotlight). Remove the config file afterward (done above).

- [ ] **Step 4: Re-run the unit tests** (ensure nothing regressed; agent code links but isn't invoked)

Run: `make test`
Expected: `28/28 passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/Agent.swift
git commit -m "feat: Carbon global-hotkey agent with headless run loop"
```

---

## Task 7: LaunchAgent template + install flow

**Files:**
- Create: `launchd/com.genie.br.plist.template`

(The Makefile targets `hotkey-install`/`hotkey-uninstall` were written in Task 1 and reference this template.)

- [ ] **Step 1: Create `launchd/com.genie.br.plist.template`:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.genie.br</string>
  <key>ProgramArguments</key>
  <array>
    <string>__BR_PATH__</string>
    <string>agent</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>__LOG_PATH__</string>
  <key>StandardOutPath</key>
  <string>__LOG_PATH__</string>
</dict>
</plist>
```

- [ ] **Step 2: Install the binary and load the agent (manual, end-to-end)**

Run (no-sudo path):
```bash
make install PREFIX=$HOME/.local
make hotkey-install PREFIX=$HOME/.local
```
Expected: `installed .../.local/bin/br`, then `hotkey agent loaded ...`. Confirm it's running:
```bash
launchctl print gui/$(id -u)/com.genie.br | grep -E 'state|program' | head
```
Expected: shows `state = running` and the program path ending in `/bin/br`.

- [ ] **Step 3: Verify the hotkey works via the LaunchAgent**

Press **Control-Option-Command-B** in any app → screen blacks out; press again → restores. (No terminal needed — this is the core requirement.)

- [ ] **Step 4: Verify clean teardown**

Run: `make hotkey-uninstall PREFIX=$HOME/.local`
Expected: `hotkey agent unloaded`; the plist is gone:
```bash
ls ~/Library/LaunchAgents/com.genie.br.plist 2>&1   # -> No such file
launchctl print gui/$(id -u)/com.genie.br 2>&1 | head -1   # -> Could not find service
```
Then reload it for normal use: `make hotkey-install PREFIX=$HOME/.local`.

- [ ] **Step 5: Commit**

```bash
git add launchd/
git commit -m "feat: LaunchAgent template for the hotkey agent"
```

---

## Task 8: README + full manual acceptance

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`:**

```markdown
# br — instant built-in display brightness toggle

`br` blacks out your Mac's built-in display (0%) and restores it to 100%
instantly. Because the Mac stays awake at 0% brightness, a bundled global-hotkey
agent lets you restore the screen without needing to see a terminal.

## Build & install

```bash
make
make install PREFIX=$HOME/.local      # no sudo; or: sudo make install (PREFIX=/usr/local)
```

Ensure your install bin is on `PATH` (for `$HOME/.local`: add `export PATH="$HOME/.local/bin:$PATH"`).

## Usage

| Command     | Action                         |
|-------------|--------------------------------|
| `br`        | Toggle 0% ↔ 100%               |
| `br on`     | 100%                           |
| `br off`    | 0%                             |
| `br 80`     | Set 80% (any integer 0–100)    |
| `br status` | Print current percent          |
| `br -h`     | Help                           |

## Global hotkey

```bash
make hotkey-install PREFIX=$HOME/.local
```

Default hotkey: **Control-Option-Command-B**. Press it anywhere to black out the
screen; press again to restore — even while the screen is black.

Change the hotkey by writing one line to `~/.config/br/hotkey.conf`, e.g.:

```
ctrl+opt+cmd+b
```

Separators `+`, `-`, or space; modifiers `ctrl`, `opt`/`alt`, `cmd`, `shift`;
keys `a`–`z`, `0`–`9`, `f1`–`f20`, `space`, `escape`, `return`, `tab`. After
editing, reload: `make hotkey-install PREFIX=$HOME/.local`.

Remove the agent: `make hotkey-uninstall PREFIX=$HOME/.local`. Agent logs:
`~/Library/Logs/br-agent.log`.

## Notes / caveats

- Controls the **built-in** display only.
- macOS auto-brightness (ambient sensor) may slowly raise brightness after `br off`.
- Apple panels keep a faint glow at 0% (not pure black) — expected.
- The hotkey uses Carbon `RegisterEventHotKey`, which needs **no** Accessibility
  permission.

## Develop

```bash
make test     # non-destructive: unit tests + a brightness get/set round-trip
make clean
```
```

- [ ] **Step 2: Full manual acceptance pass**

With the agent installed (`make hotkey-install PREFIX=$HOME/.local`), verify each:
```bash
./br status            # prints current %, e.g. 35
./br 50                # screen dims to ~50%
./br status            # prints 50
./br off               # screen black
# press Control-Option-Command-B  -> screen restores to 100%
# press Control-Option-Command-B  -> screen black
# press Control-Option-Command-B  -> screen restores to 100%
./br on                # explicitly 100%
make test              # 28/28 passed
```
Expected: every step behaves as commented; brightness changes are visible and instant; the hotkey works without a terminal.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with usage, hotkey config, caveats"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** CLI `toggle`/`on`/`off`/`<N>`/`status`/`-h` (Tasks 2,4); exit codes 0/1/2 (Task 4); built-in display via `CGDisplayIsBuiltin` + DisplayServices (Task 3); agent mode + Carbon hotkey + accessory run loop (Task 6); default hotkey `⌃⌥⌘B` keyCode 11 / mods 6400 + config parsing (Task 5); LaunchAgent + `make` targets (Tasks 1,7); README caveats (Task 8); non-destructive `make test` (Tasks 1,3). All spec sections map to a task.
- **Placeholder scan:** the only `TEMPORARY` stub (Task 4) is explicitly replaced in Task 6; no TODO/TBD remain in shipped code.
- **Type consistency:** `Command`, `BuiltinDisplay`, `Hotkey`, `parsePercent`, `parseArgs`, `parseHotkey`, `keyCode(for:)`, `loadHotkey`, `runCLI`, `runAgent`, `errPrint`, `withDisplay` are defined once and referenced with matching signatures across tasks. Modifier math (`6400`, `768`) matches the constants. `br-test` compiles `LIB + Tests/main.swift` (no `Sources/main.swift`), so there is exactly one top-level entry per binary.
```
