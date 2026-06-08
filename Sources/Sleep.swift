import Foundation

/// Path to the scoped sudoers rule installed by `make sleep-setup`.
private let sudoersPath = "/etc/sudoers.d/br"

/// Whether sleep/clamshell coupling should change with a given brightness endpoint.
enum SleepIntent: Equatable {
    case disable   // brightness off  -> keep awake with lid closed (clamshell)
    case enable    // brightness full -> restore normal sleep
    case leave     // intermediate    -> don't touch sleep
}

/// Decide the sleep coupling for a brightness value (pure; thresholds absorb float fuzz).
func sleepIntent(forBrightness value: Float) -> SleepIntent {
    if value <= 0.001 { return .disable }
    if value >= 0.999 { return .enable }
    return .leave
}

/// Run `sudo -n pmset -c disablesleep <1|0>`. Requires the NOPASSWD sudoers rule
/// from `make sleep-setup`. Never throws; on failure prints a one-line hint to
/// stderr and returns false so brightness control still succeeds.
@discardableResult
func setSleepDisabled(_ disabled: Bool) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    proc.arguments = ["-n", "/usr/bin/pmset", "-c", "disablesleep", disabled ? "1" : "0"]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        errPrint("br: could not launch pmset (\(error.localizedDescription))")
        return false
    }
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        errPrint("br: sleep control failed — run: sudo make sleep-setup")
        return false
    }
    return true
}

/// Couple clamshell/sleep to brightness endpoints. Opt-in: only acts when the
/// sudoers helper is installed, so without `make sleep-setup` brightness behaves
/// exactly as before (no pmset call, no warning).
func applySleepCoupling(forBrightness value: Float) {
    guard FileManager.default.fileExists(atPath: sudoersPath) else { return }
    switch sleepIntent(forBrightness: value) {
    case .disable: setSleepDisabled(true)
    case .enable:  setSleepDisabled(false)
    case .leave:   break
    }
}
