import AppKit

/// Injected by the window; documents created without a store remain entirely in memory.
struct EditorPreferences {
    let defaults: UserDefaults

    var color: NSColor {
        get {
            guard let values = defaults.array(forKey: "editor.color") as? [Double], values.count == 4,
                  values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return NSColor(ShotTheme.accent) }
            return NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: 1)
        }
        nonmutating set {
            guard let color = newValue.usingColorSpace(.sRGB) else { return }
            defaults.set([color.redComponent, color.greenComponent, color.blueComponent, 1], forKey: "editor.color")
        }
    }
    var lineWidth: CGFloat {
        get { Self.validLineWidth(number("editor.lineWidth", fallback: 5)) }
        nonmutating set { defaults.set(Double(Self.validLineWidth(newValue)), forKey: "editor.lineWidth") }
    }
    var fontSize: CGFloat {
        get { Self.validFontSize(number("editor.fontSize", fallback: 35)) }
        nonmutating set { defaults.set(Double(Self.validFontSize(newValue)), forKey: "editor.fontSize") }
    }
    var padding: Int {
        get { Int(Self.bounded(number("editor.padding", fallback: 0), range: 0...1024, fallback: 0)) }
        nonmutating set { defaults.set(max(0, min(1024, newValue)), forKey: "editor.padding") }
    }
    static func validLineWidth(_ value: CGFloat) -> CGFloat { bounded(value, range: 1...20, fallback: 5) }
    static func validFontSize(_ value: CGFloat) -> CGFloat { bounded(value, range: 12...160, fallback: 35) }
    private func number(_ key: String, fallback: CGFloat) -> CGFloat {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
        return CGFloat(number.doubleValue)
    }
    private static func bounded(_ value: CGFloat, range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        value.isFinite ? max(range.lowerBound, min(range.upperBound, value)) : fallback
    }
}
