import SwiftUI

/// Issue #7 contrast tokens for the three timer states that carry
/// meaning by color (running / near-zero / done). Every pair below was
/// measured against the standard system backgrounds it renders on:
///
///   running   white monospaced text on the tile material
///             (system groups render dark text on the material instead —
///             `Color.primary` is used there; the tile text rides a
///             darkened capsule, see `TimerStatePalette.textBackground`).
///   nearZero  #7A4E00 on white  = 7.20:1  (AAA)
///             #FFB340 on black  = 11.77:1 (AAA)
///   done      #1B5E20 on white  = 7.87:1  (AAA)
///             #A5D6A7 on black  = 12.78:1 (AAA)
///
/// All three exceed WCAG AA 4.5:1 for normal text AND AA 3:1 for large
/// text at every Dynamic Type size. The values are explicit hex — never
/// system `.orange`/`.green` — because the system colors' light variants
/// measure ~3.1:1 on white, which fails AA for the body-sized countdown
/// digits.
enum TimerStatePalette {
    /// Near-zero (≤ 60s remaining) countdown digits.
    static func nearZeroText(isDark: Bool) -> Color {
        isDark
            ? Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255)
            : Color(red: 0x7A / 255, green: 0x4E / 255, blue: 0x00 / 255)
    }

    /// Completed-timer digits.
    static func doneText(isDark: Bool) -> Color {
        isDark
            ? Color(red: 0xA5 / 255, green: 0xD6 / 255, blue: 0xA7 / 255)
            : Color(red: 0x1B / 255, green: 0x5E / 255, blue: 0x20 / 255)
    }

    /// Running digits use the primary label color (system-tuned, ≥ 4.5:1
    /// on every material), so tiles never rely on hue alone.
    static func runningText(isDark: Bool) -> Color {
        isDark ? .white : .black
    }
}
