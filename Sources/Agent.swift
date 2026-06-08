import Foundation
import Cocoa
import Carbon.HIToolbox

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
