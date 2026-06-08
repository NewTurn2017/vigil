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
