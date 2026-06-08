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

/// Ensure the keep-awake caffeinate job is running. No-op if already running (so we
/// never kill a live assertion and trip launchd's respawn throttle). Returns false
/// only if the job is not loaded (i.e. `make hotkey-install` has not run).
func awakeEnsureOn() -> Bool {
    if awakeIsOn() { return true }
    return launchctl(["kickstart", awakeTarget()]) == 0
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
