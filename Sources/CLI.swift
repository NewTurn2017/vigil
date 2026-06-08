import Foundation

/// Parse a brightness percentage argument. Returns 0...100 on success, else nil.
func parsePercent(_ s: String) -> Int? {
    guard let n = Int(s), (0...100).contains(n) else { return nil }
    return n
}

/// A parsed command-line intent.
enum Command: Equatable {
    case toggle
    case set(Int)            // 0...100
    case status
    case help
    case agent
    case usageError(String)
}

/// Parse argv (excluding program name) into a Command.
func parseArgs(_ args: [String]) -> Command {
    guard let first = args.first else { return .toggle }
    if args.count > 1 { return .usageError("too many arguments") }
    switch first {
    case "on":           return .set(100)
    case "off":          return .set(0)
    case "status":       return .status
    case "agent":        return .agent
    case "-h", "--help": return .help
    default:
        if let n = parsePercent(first) { return .set(n) }
        return .usageError("unknown command or invalid percentage: \(first)")
    }
}
