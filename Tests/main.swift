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

// === SUMMARY (keep last) ===
print("\n\(testsRun - testsFailed)/\(testsRun) passed")
exit(testsFailed == 0 ? 0 : 1)
