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

// === SUMMARY (keep last) ===
print("\n\(testsRun - testsFailed)/\(testsRun) passed")
exit(testsFailed == 0 ? 0 : 1)
