# `br` Power Modes (work/away/sleep) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three power modes to `br` — `work` (awake + screen on), `away` (awake + screen off now), `sleep` (sleep now) — as CLI subcommands and global hotkeys, making `br` a root-free Amphetamine replacement.

**Architecture:** Keep-awake is a launchd-managed `caffeinate -i` job (`com.genie.br.awake`, `RunAtLoad=false`, no `KeepAlive`) toggled with `launchctl kickstart`/`kill`. `away`/`sleep` use `pmset displaysleepnow`/`sleepnow`. A new `Sources/Awake.swift` holds this; `CLI.swift` and `Agent.swift` gain the new commands/hotkey actions. Everything is session-scoped (off after reboot).

**Tech Stack:** Swift 6.x, `swiftc`, `launchctl`, `caffeinate`, `pmset`, Carbon hotkeys (existing), DisplayServices (existing).

**Spec:** `docs/superpowers/specs/2026-06-08-br-power-modes-design.md`

---

## File Structure

| File | Change |
|------|--------|
| `Sources/Awake.swift` | **New** — launchctl job mgmt (`awakeEnsureOn`/`awakeOff`/`awakeIsOn`), `displaySleepNow`/`sleepNow`, `runWork`/`runAway`/`runSleep` |
| `Sources/CLI.swift` | `Command` cases + `parseArgs` for `work`/`away`/`sleep`/`awake on\|off\|status`; `runCLI` dispatch |
| `Sources/Agent.swift` | `HotkeyAction` `.work`/`.away`/`.sleep`; `parseBindings`; `actionID` (made internal); `performAction` ids 4/5/6 |
| `launchd/com.genie.br.awake.plist.template` | **New** — runs `/usr/bin/caffeinate -i` |
| `Makefile` | `LIB` += `Awake.swift`; `hotkey-install`/`hotkey-uninstall` manage the awake job |
| `Tests/main.swift` | unit checks for the new parsing |
| `README.md` | EN/KO power-modes section |

---

## Task 1: Verify the `pmset` action root requirement (manual gate)

This is the one design unknown. `pmset displaysleepnow`/`sleepnow` are *actions* (expected to work for the console user without root), unlike *settings*. Confirm before writing `Awake.swift`.

**Files:** none (verification only).

- [ ] **Step 1: Test `displaysleepnow` without sudo**

Run (your screen will briefly sleep; move the mouse to wake it):
```bash
pmset displaysleepnow; echo "exit=$?"
```
Expected: the display sleeps and `exit=0` (no "must be run as root" error).

- [ ] **Step 2: Record the outcome**

- If `exit=0`: **no root needed.** Proceed; `Awake.swift` (Task 2) calls `/usr/bin/pmset` directly. `sleepnow` is the same privilege class, so it needs no root either.
- If it errors with a permission/root message: root **is** needed. Then in Task 2 write `displaySleepNow()`/`sleepNow()` to exec `/usr/bin/sudo` with args `["-n", "/usr/bin/pmset", "displaysleepnow"|"sleepnow"]`, and add a Task between 5 and 6 to extend `sudoers/br.sudoers.template` with `/usr/bin/pmset displaysleepnow, /usr/bin/pmset sleepnow` and re-run `make sleep-setup`.

This plan's code assumes the **no-root** outcome (the expected case).

---

## Task 2: `Awake.swift` core + plist template + build wiring

**Files:**
- Create: `Sources/Awake.swift`
- Create: `launchd/com.genie.br.awake.plist.template`
- Modify: `Makefile` (the `LIB` line)

- [ ] **Step 1: Create the keep-awake plist template** `launchd/com.genie.br.awake.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.genie.br.awake</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
```

(`RunAtLoad=false`, no `KeepAlive` → loaded-but-idle at login; started only on demand → session-scoped.)

- [ ] **Step 2: Create `Sources/Awake.swift`:**

```swift
import Foundation

private let awakeLabel = "com.genie.br.awake"
private func awakeTarget() -> String { "gui/\(getuid())/\(awakeLabel)" }

/// Run launchctl with args; return its exit status (or -1 if it could not launch).
@discardableResult
private func launchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Start (or restart) the keep-awake caffeinate job. Returns false if the job
/// is not loaded (i.e. `make hotkey-install` has not run).
func awakeEnsureOn() -> Bool {
    return launchctl(["kickstart", "-k", awakeTarget()]) == 0
}

/// Stop the keep-awake job (the launchd job stays loaded but idle).
func awakeOff() {
    _ = launchctl(["kill", "SIGTERM", awakeTarget()])
}

/// True if the keep-awake job is currently running.
func awakeIsOn() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", awakeTarget()]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let s = String(data: data, encoding: .utf8) else { return false }
    return s.contains("state = running")
}

/// Run a `pmset` action (no root needed for actions per Task 1). Returns success.
@discardableResult
private func pmsetAction(_ action: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = [action]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func displaySleepNow() -> Bool { pmsetAction("displaysleepnow") }
func sleepNow() -> Bool { pmsetAction("sleepnow") }

/// work: keep-awake ON + brightness 100%.
func runWork() -> Int32 {
    var ok = true
    if !awakeEnsureOn() { errPrint("br: keep-awake unavailable — run: make hotkey-install"); ok = false }
    do { try BuiltinDisplay().setBrightness(1.0) } catch { errPrint("br: \(error)"); ok = false }
    return ok ? 0 : 1
}

/// away: keep-awake ON + display sleep now.
func runAway() -> Int32 {
    var ok = true
    if !awakeEnsureOn() { errPrint("br: keep-awake unavailable — run: make hotkey-install"); ok = false }
    if !displaySleepNow() { errPrint("br: displaysleepnow failed"); ok = false }
    return ok ? 0 : 1
}

/// sleep: keep-awake OFF + sleep now.
func runSleep() -> Int32 {
    awakeOff()
    if !sleepNow() { errPrint("br: sleepnow failed"); return 1 }
    return 0
}
```

- [ ] **Step 3: Add `Awake.swift` to the build** — in `Makefile`, change the `LIB` line:

```make
LIB := Sources/Brightness.swift Sources/CLI.swift Sources/Agent.swift Sources/Sleep.swift Sources/Awake.swift
```

- [ ] **Step 4: Build to verify it compiles** (nothing calls the new functions yet)

Run: `make`
Expected: compiles cleanly, produces `./br`. (`br` behaves exactly as before.)

- [ ] **Step 5: Run existing tests (no regression)**

Run: `make test`
Expected: `39/39 passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Awake.swift launchd/com.genie.br.awake.plist.template Makefile
git commit -m "feat: Awake.swift (caffeinate job + pmset actions + work/away/sleep)"
```

---

## Task 3: CLI commands + dispatch (TDD)

**Files:**
- Modify: `Sources/CLI.swift`
- Modify: `Tests/main.swift`

- [ ] **Step 1: Write the failing test** — in `Tests/main.swift`, insert above the `=== SUMMARY` block:

```swift
// === parseArgs: power-mode commands ===
checkEqual(parseArgs(["work"]), .work, "work -> .work")
checkEqual(parseArgs(["away"]), .away, "away -> .away")
checkEqual(parseArgs(["sleep"]), .sleep, "sleep -> .sleep")
checkEqual(parseArgs(["awake", "on"]), .awakeOn, "awake on -> .awakeOn")
checkEqual(parseArgs(["awake", "off"]), .awakeOff, "awake off -> .awakeOff")
checkEqual(parseArgs(["awake", "status"]), .awakeStatus, "awake status -> .awakeStatus")
check(isUsageError(parseArgs(["awake"])), "awake alone -> usageError")
check(isUsageError(parseArgs(["awake", "bad"])), "awake bad -> usageError")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: compile error — `type 'Command' has no member 'work'`.

- [ ] **Step 3: Add the `Command` cases** — in `Sources/CLI.swift`, replace the `enum Command` block with:

```swift
/// A parsed command-line intent.
enum Command: Equatable {
    case toggle
    case set(Int)            // 0...100
    case status
    case help
    case agent
    case work
    case away
    case sleep
    case awakeOn
    case awakeOff
    case awakeStatus
    case usageError(String)
}
```

- [ ] **Step 4: Update `parseArgs`** — in `Sources/CLI.swift`, replace the whole `parseArgs` function with:

```swift
/// Parse argv (excluding program name) into a Command.
func parseArgs(_ args: [String]) -> Command {
    guard let first = args.first else { return .toggle }
    if first == "awake" {
        guard args.count == 2 else { return .usageError("usage: br awake on|off|status") }
        switch args[1] {
        case "on":     return .awakeOn
        case "off":    return .awakeOff
        case "status": return .awakeStatus
        default:       return .usageError("unknown awake subcommand: \(args[1])")
        }
    }
    if args.count > 1 { return .usageError("too many arguments") }
    switch first {
    case "on":           return .set(100)
    case "off":          return .set(0)
    case "status":       return .status
    case "work":         return .work
    case "away":         return .away
    case "sleep":        return .sleep
    case "agent":        return .agent
    case "-h", "--help": return .help
    default:
        if let n = parsePercent(first) { return .set(n) }
        return .usageError("unknown command or invalid percentage: \(first)")
    }
}
```

- [ ] **Step 5: Add dispatch + usage** — in `Sources/CLI.swift`, replace the `runCLI` function with:

```swift
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
        return withDisplay { d in
            let v = Float(n) / 100.0
            try d.setBrightness(v)
            applySleepCoupling(forBrightness: v)
        }
    case .toggle:
        return withDisplay { d in
            let v = try d.toggle()
            applySleepCoupling(forBrightness: v)
        }
    case .work:  return runWork()
    case .away:  return runAway()
    case .sleep: return runSleep()
    case .awakeOn:
        if awakeEnsureOn() { return 0 }
        errPrint("br: keep-awake unavailable — run: make hotkey-install"); return 1
    case .awakeOff:
        awakeOff(); return 0
    case .awakeStatus:
        print("awake: \(awakeIsOn() ? "on" : "off")"); return 0
    }
}
```

- [ ] **Step 6: Update `usageText`** — in `Sources/CLI.swift`, replace the `usageText` function with:

```swift
func usageText() -> String {
    return """
    br — built-in display brightness + power modes

    brightness:
      br            toggle 0% <-> 100%
      br on/off     100% / 0%
      br <0-100>    set that percent
      br status     print current percent

    power modes:
      br work       keep awake + screen on (100%)
      br away       keep awake + screen off now
      br sleep      sleep the Mac now
      br awake on   keep awake only
      br awake off  stop keeping awake
      br awake status

      br agent      run the global-hotkey agent (usually launched by launchd)
      br -h         show this help
    """
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `make test`
Expected: all new `parseArgs` lines `ok`; summary count increases by 8 (e.g. `47/47 passed`).

- [ ] **Step 8: Quick CLI smoke (non-destructive)**

Run:
```bash
make
./br awake status; echo "exit=$?"
./br -h
```
Expected: `awake: off` (job not loaded yet → `awakeIsOn` false), `exit=0`; help shows the power-modes section. (Do **not** run `./br sleep` here — it would sleep the Mac.)

- [ ] **Step 9: Commit**

```bash
git add Sources/CLI.swift Tests/main.swift
git commit -m "feat: br work/away/sleep + awake on|off|status CLI commands"
```

---

## Task 4: Hotkey actions + dispatch (TDD)

**Files:**
- Modify: `Sources/Agent.swift`
- Modify: `Tests/main.swift`

- [ ] **Step 1: Write the failing test** — in `Tests/main.swift`, insert above the `=== SUMMARY` block:

```swift
// === power-mode hotkeys ===
check(parseBindings("work = cmd+shift+0").first == Binding(hotkey: Hotkey(keyCode: 29, modifiers: 768), action: .work), "work binding")
check(parseBindings("away = cmd+shift+9").first == Binding(hotkey: Hotkey(keyCode: 25, modifiers: 768), action: .away), "away binding")
check(parseBindings("sleep = cmd+shift+8").first == Binding(hotkey: Hotkey(keyCode: 28, modifiers: 768), action: .sleep), "sleep binding")
checkEqual(actionID(.work), 4, "actionID work = 4")
checkEqual(actionID(.away), 5, "actionID away = 5")
checkEqual(actionID(.sleep), 6, "actionID sleep = 6")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: compile error — `type 'HotkeyAction' has no member 'work'`.

- [ ] **Step 3: Extend `HotkeyAction`** — in `Sources/Agent.swift`, replace the `enum HotkeyAction` block with:

```swift
/// What a hotkey does when pressed.
enum HotkeyAction: Equatable {
    case on       // set 100%
    case off      // set 0%
    case toggle   // 0% <-> 100%
    case work     // keep awake + screen on
    case away     // keep awake + screen off now
    case sleep    // sleep the Mac now
}
```

- [ ] **Step 4: Accept the new actions in `parseBindings`** — in `Sources/Agent.swift`, find the `switch lhs` inside `parseBindings` and replace it with:

```swift
            switch lhs {
            case "on":     action = .on
            case "off":    action = .off
            case "toggle": action = .toggle
            case "work":   action = .work
            case "away":   action = .away
            case "sleep":  action = .sleep
            default:
                errPrint("br: unknown action '\(lhs)' (use on/off/toggle/work/away/sleep), skipping")
                continue
            }
```

- [ ] **Step 5: Make `actionID` testable + map new ids** — in `Sources/Agent.swift`, replace the `actionID` function with (note: drop `private`):

```swift
/// Fixed Carbon hotkey id per action — lets the (stateless) event handler tell them apart.
func actionID(_ a: HotkeyAction) -> UInt32 {
    switch a {
    case .on:     return 1
    case .off:    return 2
    case .toggle: return 3
    case .work:   return 4
    case .away:   return 5
    case .sleep:  return 6
    }
}
```

- [ ] **Step 6: Dispatch the new ids in `performAction`** — in `Sources/Agent.swift`, replace the `performAction` function with:

```swift
/// Run the action identified by its Carbon hotkey id.
private func performAction(id: UInt32) {
    switch id {
    case 4: _ = runWork();  return
    case 5: _ = runAway();  return
    case 6: _ = runSleep(); return
    default: break
    }
    guard let d = try? BuiltinDisplay() else { return }
    do {
        switch id {
        case 1: try d.setBrightness(1.0); applySleepCoupling(forBrightness: 1.0)   // on
        case 2: try d.setBrightness(0.0); applySleepCoupling(forBrightness: 0.0)   // off
        default: applySleepCoupling(forBrightness: try d.toggle())                 // toggle (id 3)
        }
    } catch {
        // display lost between resolve and set; ignore
    }
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `make test`
Expected: new lines `ok`; summary count increases by 6 (e.g. `53/53 passed`).

- [ ] **Step 8: Commit**

```bash
git add Sources/Agent.swift Tests/main.swift
git commit -m "feat: work/away/sleep hotkey actions (ids 4/5/6)"
```

---

## Task 5: Makefile — install/uninstall the keep-awake job

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add awake-job variables** — in `Makefile`, just after the `SUDOERS := ...` line, add:

```make
AWAKE_PLIST := com.genie.br.awake
AWAKE_LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/$(AWAKE_PLIST).plist
```

- [ ] **Step 2: Install + bootstrap the awake job in `hotkey-install`** — in `Makefile`, replace the `hotkey-install` recipe with:

```make
hotkey-install:
	@test -x "$(PREFIX)/bin/$(BIN)" || { echo "run 'make install' (maybe with sudo, or PREFIX=\$$HOME/.local) first"; exit 1; }
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed -e 's#__BR_PATH__#$(PREFIX)/bin/$(BIN)#' -e 's#__LOG_PATH__#$(LOG)#' \
		launchd/$(PLIST).plist.template > "$(LAUNCH_AGENT)"
	launchctl bootout $(DOMAIN)/$(PLIST) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) "$(LAUNCH_AGENT)"
	launchctl kickstart -k $(DOMAIN)/$(PLIST)
	cp launchd/$(AWAKE_PLIST).plist.template "$(AWAKE_LAUNCH_AGENT)"
	launchctl bootout $(DOMAIN)/$(AWAKE_PLIST) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) "$(AWAKE_LAUNCH_AGENT)"
	@echo "hotkey agent + keep-awake job loaded (awake starts OFF; default key ctrl-opt-cmd-B)."
	@echo "Logs: $(LOG)"
```

- [ ] **Step 3: Tear down the awake job in `hotkey-uninstall`** — in `Makefile`, replace the `hotkey-uninstall` recipe with:

```make
hotkey-uninstall:
	launchctl bootout $(DOMAIN)/$(PLIST) 2>/dev/null || true
	rm -f "$(LAUNCH_AGENT)"
	launchctl bootout $(DOMAIN)/$(AWAKE_PLIST) 2>/dev/null || true
	rm -f "$(AWAKE_LAUNCH_AGENT)"
	@echo "hotkey agent + keep-awake job unloaded"
```

- [ ] **Step 4: Reinstall and verify the awake job loads idle**

Run:
```bash
make install PREFIX=$HOME/.local
make hotkey-install PREFIX=$HOME/.local
launchctl print gui/$(id -u)/com.genie.br.awake >/dev/null 2>&1 && echo "awake job loaded"
~/.local/bin/br awake status
```
Expected: `awake job loaded`, then `awake: off`.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat: install/teardown the keep-awake launchd job"
```

---

## Task 6: Configure the user's hotkeys + full manual acceptance

**Files:**
- Modify: `~/.config/br/hotkey.conf` (user config, not in repo)

- [ ] **Step 1: Rewrite the hotkey config to the three power modes**

Run:
```bash
mkdir -p ~/.config/br
printf 'work  = cmd+shift+0\naway  = cmd+shift+9\nsleep = cmd+shift+8\n' > ~/.config/br/hotkey.conf
cat ~/.config/br/hotkey.conf
make hotkey-install PREFIX=$HOME/.local   # reload agent with new bindings
```
Expected: config shows the three lines; agent reloads.

- [ ] **Step 2: Verify `work` (CLI) — keep-awake on + brightness 100%**

Run:
```bash
BR=~/.local/bin/br
orig=$($BR status)
$BR work
echo "brightness=$($BR status)%  awake=$($BR awake status)"
pmset -g assertions | grep PreventUserIdleSystemSleep | head -1
$BR "$orig" >/dev/null   # restore brightness
```
Expected: `brightness=100%  awake: on`; the assertions line shows `PreventUserIdleSystemSleep 1`.

- [ ] **Step 3: Verify `away` (CLI) — screen off now, still awake**

Run (screen will sleep; move mouse to wake):
```bash
~/.local/bin/br away; echo "exit=$?"
~/.local/bin/br awake status
```
Expected: display sleeps, `exit=0`, `awake: on`. Wake the screen, then `~/.local/bin/br awake off` to stop keep-awake.

- [ ] **Step 4: Verify the hotkeys**

Press **⌘⇧0** (work) → screen full brightness, stays awake. Press **⌘⇧9** (away) → screen turns off immediately; move mouse to wake. Confirm `~/.local/bin/br awake status` → `awake: on`. Then `~/.local/bin/br awake off`.

(Optional, only if you want to confirm sleep: **⌘⇧8** or `~/.local/bin/br sleep` sleeps the Mac — skip if you don't want to sleep now.)

- [ ] **Step 5: Run the test suite**

Run: `make test`
Expected: `53/53 passed`.

- [ ] **Step 6: Commit** (nothing in-repo changed in this task; skip if `git status` is clean)

```bash
git status --short
```

---

## Task 7: README (EN/KO) + push

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a power-modes section to the English half** — in `README.md`, immediately before the line `### Clamshell mode (keep the Mac awake with the lid closed)`, insert:

````markdown
### Power modes (Amphetamine replacement)

Keep the Mac awake (it never idle-sleeps) while controlling the screen, or sleep on
demand. All root-free.

| Command     | Action                                                       |
|-------------|--------------------------------------------------------------|
| `br work`   | keep awake + screen on (100%); screen still idle-offs after the macOS timer |
| `br away`   | keep awake + screen off **now** (display sleep)              |
| `br sleep`  | stop keeping awake + sleep the Mac **now**                   |
| `br awake on` / `off` / `status` | keep-awake only / stop / show state     |

Keep-awake is session-scoped (a reboot returns to normal). Recommended hotkeys
(`~/.config/br/hotkey.conf`):

```conf
work  = cmd+shift+0
away  = cmd+shift+9
sleep = cmd+shift+8
```

After editing, reload with `make hotkey-install PREFIX=$HOME/.local`.

> **Quit Amphetamine** if you use it — while it holds a "prevent display sleep"
> assertion the screen won't turn off, defeating `work`/`away`. `br` replaces it.
````

- [ ] **Step 2: Add the Korean section** — in `README.md`, immediately before the line `### 클램쉘 모드 (덮개를 닫아도 깨어있게)`, insert:

````markdown
### 전원 모드 (Amphetamine 대체)

맥을 깨어있게(idle로 안 잠) 유지하면서 화면을 제어하거나, 원할 때 바로 재웁니다.
모두 root 불필요.

| 명령어      | 동작                                                          |
|-------------|---------------------------------------------------------------|
| `br work`   | 깨어있기 + 화면 켜기(100%); 화면은 macOS 타이머대로 idle 후 꺼짐 |
| `br away`   | 깨어있기 + 화면 **즉시** 끄기(디스플레이 슬립)                 |
| `br sleep`  | 깨어있기 해제 + **즉시** 재우기                                |
| `br awake on` / `off` / `status` | 깨어있기만 켜기 / 끄기 / 상태 표시       |

깨어있기는 세션 한정(재부팅하면 정상 복귀). 추천 단축키
(`~/.config/br/hotkey.conf`):

```conf
work  = cmd+shift+0
away  = cmd+shift+9
sleep = cmd+shift+8
```

수정 후 `make hotkey-install PREFIX=$HOME/.local`로 다시 적용.

> **Amphetamine을 쓰고 있다면 종료**하세요 — "화면 잠들기 방지"를 잡고 있으면
> 화면이 안 꺼져 `work`/`away`가 무력화됩니다. `br`가 그 역할을 대신합니다.
````

- [ ] **Step 3: Commit and push**

```bash
git add README.md
git commit -m "docs: power modes (work/away/sleep) in EN/KO README"
git push origin main
```

- [ ] **Step 4: Verify the push**

Run: `git log --oneline -1 && git status -sb`
Expected: the docs commit is `HEAD`, branch up to date with `origin/main`.

---

## Self-Review (completed during planning)

- **Spec coverage:** `work`/`away`/`sleep` + `awake on|off|status` CLI (Tasks 3); hotkey actions ids 4/5/6 (Task 4); `caffeinate -i` launchd job, session-scoped via `RunAtLoad=false`/no-`KeepAlive` (Tasks 2,5); `pmset displaysleepnow`/`sleepnow` with root verified first (Task 1); brightness-100 on `work` (Task 2 `runWork`); error messages + exit codes match the spec table (Task 2/3); user config rewrite + manual acceptance (Task 6); EN/KO README incl. Amphetamine note (Task 7). All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO; Task 1 is a real verification gate, not a placeholder; every code step shows complete code.
- **Type consistency:** `Command` cases (`.work/.away/.sleep/.awakeOn/.awakeOff/.awakeStatus`), `HotkeyAction` (`.work/.away/.sleep`), `actionID` ids 4/5/6, and `runWork/runAway/runSleep/awakeEnsureOn/awakeOff/awakeIsOn/displaySleepNow/sleepNow` are defined once (Task 2) and referenced consistently (Tasks 3,4). `actionID` is made internal in Task 4 so the test can call it. Key codes: `0`→29, `9`→25, `8`→28; `cmd+shift`→768 — consistent with the existing keymap.
