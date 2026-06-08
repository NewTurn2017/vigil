import Foundation
import Cocoa
import Carbon.HIToolbox

struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// What a hotkey does when pressed.
enum HotkeyAction: Equatable {
    case on       // set 100%
    case off      // set 0%
    case toggle   // 0% <-> 100%
    case work     // keep awake + screen on
    case away     // keep awake + screen off now
    case sleep    // sleep the Mac now
}

/// A hotkey bound to an action.
struct Binding: Equatable {
    var hotkey: Hotkey
    var action: HotkeyAction
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

/// Parse a hotkey string like "cmd+shift+0" (separators: + - space). nil if no key.
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

/// Parse a hotkey config into bindings. Lines are `action = combo` where action is
/// `on`, `off`, or `toggle`; a line with no `=` is treated as a toggle combo
/// (legacy single-line format). Blank lines and `#` comments are ignored.
func parseBindings(_ text: String) -> [Binding] {
    var result: [Binding] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        var action: HotkeyAction = .toggle
        var comboStr = line
        if let eq = line.firstIndex(of: "=") {
            let lhs = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            comboStr = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch lhs {
            case "on":     action = .on
            case "off":    action = .off
            case "toggle": action = .toggle
            case "work":   action = .work
            case "away":   action = .away
            case "sleep":  action = .sleep
            default:
                errPrint("vigil: unknown action '\(lhs)' (use on/off/toggle/work/away/sleep), skipping")
                continue
            }
        }
        if let hk = parseHotkey(comboStr) {
            result.append(Binding(hotkey: hk, action: action))
        } else {
            errPrint("vigil: could not parse hotkey '\(comboStr)', skipping")
        }
    }
    return result
}

/// Load bindings from ~/.config/vigil/hotkey.conf; fall back to a single default toggle.
func loadBindings() -> [Binding] {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vigil/hotkey.conf")
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        return [Binding(hotkey: defaultHotkey, action: .toggle)]
    }
    let bindings = parseBindings(raw)
    if bindings.isEmpty {
        errPrint("vigil: no valid hotkeys in config, using default ctrl-opt-cmd-B toggle")
        return [Binding(hotkey: defaultHotkey, action: .toggle)]
    }
    return bindings
}

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

/// Run the action identified by its Carbon hotkey id, including sleep/clamshell coupling.
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
        case 1:  try d.setBrightness(1.0); applySleepCoupling(forBrightness: 1.0)   // on
        case 2:  try d.setBrightness(0.0); applySleepCoupling(forBrightness: 0.0)   // off
        default: applySleepCoupling(forBrightness: try d.toggle())                  // toggle (id 3)
        }
    } catch {
        // display lost between resolve and set; ignore
    }
}

// Black overlay windows (held by the agent) that blank every display — including
// external monitors, which DisplayServices brightness cannot touch — without using
// display sleep (so macOS never locks / asks for a password).
nonisolated(unsafe) var overlayWindows: [NSWindow] = []

/// Cover every display with an opaque black, top-level window.
func showOverlays() {
    hideOverlays()
    for screen in NSScreen.screens {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.level = .screenSaver                 // above normal windows and the menu bar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = false           // absorb stray clicks while "away"
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        overlayWindows.append(w)
    }
}

/// Remove the black overlays.
func hideOverlays() {
    for w in overlayWindows { w.orderOut(nil) }
    overlayWindows.removeAll()
}

/// Run the headless global-hotkey agent. Blocks in the app run loop on success;
/// returns a nonzero exit code if no hotkey could be registered.
func runAgent() -> Int32 {
    let bindings = loadBindings()

    // One handler for all hotkeys; it reads the pressed hotkey's id and acts on it.
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hkID = EventHotKeyID()
        if let event = event {
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        }
        performAction(id: hkID.id)
        return noErr
    }, 1, &spec, nil, nil)

    var registered = 0
    for b in bindings {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x6272_746b), id: actionID(b.action)) // 'brtk'
        let status = RegisterEventHotKey(b.hotkey.keyCode, b.hotkey.modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            registered += 1
        } else {
            errPrint("vigil: could not register hotkey for \(b.action) (status \(status)); is the combo already in use?")
        }
    }
    guard registered > 0 else {
        errPrint("vigil: no hotkeys could be registered")
        return 1
    }

    // Listen for overlay show/hide requests (posted by `away`/`work` from any process).
    let darwin = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterAddObserver(darwin, nil, { _, _, _, _, _ in
        DispatchQueue.main.async { showOverlays() }
    }, "com.genie.vigil.overlay.on" as CFString, nil, .deliverImmediately)
    CFNotificationCenterAddObserver(darwin, nil, { _, _, _, _, _ in
        DispatchQueue.main.async { hideOverlays() }
    }, "com.genie.vigil.overlay.off" as CFString, nil, .deliverImmediately)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // headless: no Dock icon, no menu bar
    app.run()
    return 0   // not reached
}
