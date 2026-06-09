import AppKit

extension NSColor {
    /// Parses `#RRGGBB` or `#AARRGGBB` into an NSColor. Returns nil if the
    /// string does not match.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard [6, 8].contains(s.count), let v = UInt32(s, radix: 16) else {
            return nil
        }
        let a, r, g, b: CGFloat
        if s.count == 8 {
            a = CGFloat((v >> 24) & 0xFF) / 255.0
            r = CGFloat((v >> 16) & 0xFF) / 255.0
            g = CGFloat((v >> 8)  & 0xFF) / 255.0
            b = CGFloat( v        & 0xFF) / 255.0
        } else {
            a = 1.0
            r = CGFloat((v >> 16) & 0xFF) / 255.0
            g = CGFloat((v >> 8)  & 0xFF) / 255.0
            b = CGFloat( v        & 0xFF) / 255.0
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent   * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent  * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
