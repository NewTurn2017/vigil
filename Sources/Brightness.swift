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

    /// If lit (> eps), go dark; otherwise go to 100%. Returns the value it set.
    @discardableResult
    func toggle() throws -> Float {
        let eps: Float = 0.01
        let current = try getBrightness()
        let target: Float = current > eps ? 0.0 : 1.0
        try setBrightness(target)
        return target
    }
}
