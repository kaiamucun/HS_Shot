import SwiftUI
import AppKit

/// A light editing desk: quiet surfaces, clear text, and one calm action color.
enum ShotTheme {
    static let background = Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
    static let sidebar = Color(red: 238 / 255, green: 242 / 255, blue: 247 / 255)
    static let panel = Color.white
    static let canvas = Color(red: 237 / 255, green: 241 / 255, blue: 246 / 255)
    static let text = Color(red: 38 / 255, green: 51 / 255, blue: 73 / 255)
    static let muted = Color(red: 100 / 255, green: 116 / 255, blue: 139 / 255)
    static let accent = Color(red: 46 / 255, green: 110 / 255, blue: 221 / 255)
    static let accentSoft = Color(red: 234 / 255, green: 241 / 255, blue: 252 / 255)
    static let border = Color(red: 223 / 255, green: 229 / 255, blue: 238 / 255)
    static let onAccent = Color.white
}
