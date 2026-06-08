import Foundation

/// Parse a brightness percentage argument. Returns 0...100 on success, else nil.
func parsePercent(_ s: String) -> Int? {
    guard let n = Int(s), (0...100).contains(n) else { return nil }
    return n
}
