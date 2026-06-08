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

// === hotkey parsing ===
check(parseHotkey("ctrl+opt+cmd+b") == Hotkey(keyCode: 11, modifiers: 6400), "parse ctrl+opt+cmd+b")
check(parseHotkey("cmd+shift+l") == Hotkey(keyCode: 37, modifiers: 768), "parse cmd+shift+l")
check(parseHotkey("f13") == Hotkey(keyCode: 105, modifiers: 0), "parse f13 (no mods)")
check(parseHotkey("CMD-B") == Hotkey(keyCode: 11, modifiers: 256), "parse CMD-B (case/dash)")
check(parseHotkey("") == nil, "empty -> nil")
check(parseHotkey("cmd+shift") == nil, "mods only -> nil")
check(parseHotkey("cmd+zzz") == nil, "unknown key -> nil")
check(defaultHotkey == Hotkey(keyCode: 11, modifiers: 6400), "default is ctrl-opt-cmd-B")

// === parseBindings (per-action hotkeys) ===
let cfg = "on = cmd+shift+0\noff = cmd+shift+9\n"
let pb = parseBindings(cfg)
checkEqual(pb.count, 2, "two bindings parsed")
check(pb.contains(Binding(hotkey: Hotkey(keyCode: 29, modifiers: 768), action: .on)),
      "on -> cmd+shift+0 (key 29, mods 768)")
check(pb.contains(Binding(hotkey: Hotkey(keyCode: 25, modifiers: 768), action: .off)),
      "off -> cmd+shift+9 (key 25, mods 768)")
check(parseBindings("ctrl+opt+cmd+b").first == Binding(hotkey: Hotkey(keyCode: 11, modifiers: 6400), action: .toggle),
      "bare line -> toggle (legacy format)")
checkEqual(parseBindings("# comment\n\non=cmd+shift+0\n").count, 1, "skip comments and blank lines")
checkEqual(parseBindings("foo = cmd+b").count, 0, "unknown action skipped")
checkEqual(parseBindings("on = cmd+nope").count, 0, "unparseable combo skipped")

// === sleepIntent (clamshell coupling decision; pure, no pmset side effect) ===
checkEqual(sleepIntent(forBrightness: 0.0), .disable, "0% -> disable sleep (clamshell)")
checkEqual(sleepIntent(forBrightness: 1.0), .enable, "100% -> enable sleep")
checkEqual(sleepIntent(forBrightness: 0.5), .leave, "50% -> leave sleep unchanged")
checkEqual(sleepIntent(forBrightness: 0.34), .leave, "34% -> leave sleep unchanged")

// === parseArgs: power-mode commands ===
checkEqual(parseArgs(["work"]), .work, "work -> .work")
checkEqual(parseArgs(["away"]), .away, "away -> .away")
checkEqual(parseArgs(["sleep"]), .sleep, "sleep -> .sleep")
checkEqual(parseArgs(["awake", "on"]), .awakeOn, "awake on -> .awakeOn")
checkEqual(parseArgs(["awake", "off"]), .awakeOff, "awake off -> .awakeOff")
checkEqual(parseArgs(["awake", "status"]), .awakeStatus, "awake status -> .awakeStatus")
check(isUsageError(parseArgs(["awake"])), "awake alone -> usageError")
check(isUsageError(parseArgs(["awake", "bad"])), "awake bad -> usageError")

// === power-mode hotkeys ===
check(parseBindings("work = cmd+shift+0").first == Binding(hotkey: Hotkey(keyCode: 29, modifiers: 768), action: .work), "work binding")
check(parseBindings("away = cmd+shift+9").first == Binding(hotkey: Hotkey(keyCode: 25, modifiers: 768), action: .away), "away binding")
check(parseBindings("sleep = cmd+shift+8").first == Binding(hotkey: Hotkey(keyCode: 28, modifiers: 768), action: .sleep), "sleep binding")
checkEqual(actionID(.work), 4, "actionID work = 4")
checkEqual(actionID(.away), 5, "actionID away = 5")
checkEqual(actionID(.sleep), 6, "actionID sleep = 6")

// === display-awake assertion (the away no-lock fix; integration, non-destructive) ===
func pmsetAssertions() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "assertions"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}
let assertionName = "Vigil: keep display awake (no idle lock)"
check(!pmsetAssertions().contains(assertionName), "no display assertion held before hold")
holdDisplayAwake()
check(displayAssertionHeld, "displayAssertionHeld true after holdDisplayAwake()")
check(pmsetAssertions().contains(assertionName), "PreventUserIdleDisplaySleep assertion visible to OS while away")
holdDisplayAwake()  // idempotent: second hold must not leak a second assertion
check(displayAssertionHeld, "second holdDisplayAwake() is a no-op")
releaseDisplayAwake()
check(!displayAssertionHeld, "displayAssertionHeld false after releaseDisplayAwake()")
check(!pmsetAssertions().contains(assertionName), "assertion gone from OS after release (work/sleep won't lock-block)")

// === auto-away: duration + threshold config parsing ===
checkEqual(parseDurationSeconds("10m") ?? -1, 600, "10m -> 600s")
checkEqual(parseDurationSeconds("90s") ?? -1, 90, "90s -> 90s")
checkEqual(parseDurationSeconds("600") ?? -1, 600, "bare 600 -> 600s")
checkEqual(parseDurationSeconds("off") ?? -1, 0, "off -> 0 (disabled)")
checkEqual(parseDurationSeconds("never") ?? -1, 0, "never -> 0 (disabled)")
check(parseDurationSeconds("abc") == nil, "abc -> nil")
checkEqual(parseAutoAwaySeconds("away = ctrl+opt+cmd+9\nautoaway = 10m\n"), 600, "autoaway=10m parsed")
checkEqual(parseAutoAwaySeconds("idle = 5m"), 300, "idle=5m alias parsed")
checkEqual(parseAutoAwaySeconds("auto-away = 45s"), 45, "auto-away=45s alias parsed")
checkEqual(parseAutoAwaySeconds("autoaway = off"), 0, "autoaway=off disables")
checkEqual(parseAutoAwaySeconds("work = ctrl+opt+cmd+0"), 600, "no autoaway line -> default 600")
checkEqual(parseAutoAwaySeconds("# autoaway = 1m\nautoaway = 2m"), 120, "commented line ignored, real one wins")

// === auto-away: fire decision (pure) ===
check(shouldAutoAway(idleSeconds: 600, threshold: 600, awayActive: false), "idle==threshold, not away -> fire")
check(shouldAutoAway(idleSeconds: 601, threshold: 600, awayActive: false), "idle>threshold -> fire")
check(!shouldAutoAway(idleSeconds: 599, threshold: 600, awayActive: false), "idle<threshold -> no fire")
check(!shouldAutoAway(idleSeconds: 9999, threshold: 600, awayActive: true), "already away (overlays up) -> no fire")
check(!shouldAutoAway(idleSeconds: 9999, threshold: 0, awayActive: false), "threshold 0 (disabled) -> no fire")

// === SUMMARY (keep last) ===
print("\n\(testsRun - testsFailed)/\(testsRun) passed")
exit(testsFailed == 0 ? 0 : 1)
