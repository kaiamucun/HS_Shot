import AppKit

let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let bounds = NSRect(x: 48, y: 48, width: 928, height: 928)
let shape = NSBezierPath(roundedRect: bounds, xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(srgbRed: 0.91, green: 0.95, blue: 1, alpha: 1), ending: NSColor.white)!.draw(in: shape, angle: -60)
NSColor(srgbRed: 46 / 255, green: 110 / 255, blue: 221 / 255, alpha: 1).setStroke()
let path = NSBezierPath()
path.lineWidth = 46; path.lineCapStyle = .round; path.lineJoinStyle = .round
for (x, y, dx, dy) in [(CGFloat(290),CGFloat(290),CGFloat(1),CGFloat(1)), (734,290,-1,1), (290,734,1,-1), (734,734,-1,-1)] {
    path.move(to: NSPoint(x: x, y: y + 110 * dy))
    path.line(to: NSPoint(x: x, y: y))
    path.line(to: NSPoint(x: x + 110 * dx, y: y))
}
path.stroke()
NSColor(srgbRed: 46 / 255, green: 110 / 255, blue: 221 / 255, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 478, y: 478, width: 68, height: 68)).fill()
image.unlockFocus()
let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: output))
