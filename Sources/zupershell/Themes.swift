import AppKit
import SwiftTerm

// ─────────────────────────────────────────────────────────────────────────────
// Themes — 16 ANSI colors + background/foreground/cursor per theme.
//
// The ANSI palette is fed to SwiftTerm's installColors([Color]) as 16 entries
// in xterm order: black, red, green, yellow, blue, magenta, cyan, white, then
// the bright variants of the same. bg/fg/cursor are set via nativeBg/Fg + caret.
// ─────────────────────────────────────────────────────────────────────────────

struct Theme {
    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    /// 16 ANSI colors in xterm order: black, red, green, yellow, blue, magenta,
    /// cyan, white, brightBlack…brightWhite.
    let ansi: [NSColor]

    /// Convert the ANSI palette into SwiftTerm's 16-bit Color type.
    var swiftTermPalette: [SwiftTerm.Color] {
        ansi.map { SwiftTerm.Color(red: $0.r16, green: $0.g16, blue: $0.b16) }
    }
}

enum Themes {
    static let all: [Theme] = [aura, solarizedDark, githubDark]
    static func byName(_ name: String) -> Theme { all.first { $0.name == name } ?? aura }

    /// Aura — Mike's default, matches ~/terminal-capabilities.html's palette.
    static let aura = Theme(
        name: "Aura",
        background: hex("#15141b"),
        foreground: hex("#edecee"),
        cursor:     hex("#a277ff"),
        ansi: [
            hex("#110f18"),  // 0  black
            hex("#ff6767"),  // 1  red
            hex("#61ffca"),  // 2  green
            hex("#ffca85"),  // 3  yellow
            hex("#a277ff"),  // 4  blue     (aura leans purple)
            hex("#a277ff"),  // 5  magenta
            hex("#82e2ff"),  // 6  cyan
            hex("#edecee"),  // 7  white
            hex("#6d6d6d"),  // 8  bright black
            hex("#ff8080"),  // 9  bright red
            hex("#7effd6"),  // 10 bright green
            hex("#ffd699"),  // 11 bright yellow
            hex("#b48fff"),  // 12 bright blue
            hex("#b48fff"),  // 13 bright magenta
            hex("#a1eaff"),  // 14 bright cyan
            hex("#ffffff"),  // 15 bright white
        ]
    )

    /// Solarized Dark — Ethan Schoonover's timeless.
    static let solarizedDark = Theme(
        name: "Solarized Dark",
        background: hex("#002b36"),
        foreground: hex("#839496"),
        cursor:     hex("#93a1a1"),
        ansi: [
            hex("#073642"), hex("#dc322f"), hex("#859900"), hex("#b58900"),
            hex("#268bd2"), hex("#d33682"), hex("#2aa198"), hex("#eee8d5"),
            hex("#002b36"), hex("#cb4b16"), hex("#586e75"), hex("#657b83"),
            hex("#839496"), hex("#6c71c4"), hex("#93a1a1"), hex("#fdf6e3"),
        ]
    )

    /// GitHub Dark — muted, easy on the eyes.
    static let githubDark = Theme(
        name: "GitHub Dark",
        background: hex("#0d1117"),
        foreground: hex("#c9d1d9"),
        cursor:     hex("#58a6ff"),
        ansi: [
            hex("#484f58"), hex("#ff7b72"), hex("#3fb950"), hex("#d29922"),
            hex("#58a6ff"), hex("#bc8cff"), hex("#39c5cf"), hex("#b1bac4"),
            hex("#6e7681"), hex("#ffa198"), hex("#56d364"), hex("#e3b341"),
            hex("#79c0ff"), hex("#d2a8ff"), hex("#56d4dd"), hex("#f0f6fc"),
        ]
    )

    private static func hex(_ s: String) -> NSColor {
        var h = s.dropFirst(s.hasPrefix("#") ? 1 : 0)
        var v: UInt64 = 0; Scanner(string: String(h)).scanHexInt64(&v)
        return NSColor(
            red:   CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >>  8) & 0xff) / 255,
            blue:  CGFloat( v        & 0xff) / 255,
            alpha: 1
        )
    }
}

// Convenience: NSColor → SwiftTerm.Color needs UInt16 channels.
extension NSColor {
    var r16: UInt16 { UInt16(clamping: Int((usingColorSpace(.sRGB)?.redComponent   ?? 0) * 65535)) }
    var g16: UInt16 { UInt16(clamping: Int((usingColorSpace(.sRGB)?.greenComponent ?? 0) * 65535)) }
    var b16: UInt16 { UInt16(clamping: Int((usingColorSpace(.sRGB)?.blueComponent  ?? 0) * 65535)) }
}
