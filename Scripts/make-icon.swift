import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.14, green: 0.19, blue: 0.25, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196).fill()
NSColor(calibratedRed: 0.31, green: 0.66, blue: 1, alpha: 1).setStroke()
let path = NSBezierPath(); path.lineWidth = 58; path.lineCapStyle = .round; path.lineJoinStyle = .round
path.move(to: NSPoint(x: 272, y: 655)); path.line(to: NSPoint(x: 418, y: 513)); path.line(to: NSPoint(x: 272, y: 371)); path.stroke()
NSColor.white.setStroke()
let line = NSBezierPath(); line.lineWidth = 54; line.lineCapStyle = .round
line.move(to: NSPoint(x: 506, y: 371)); line.line(to: NSPoint(x: 736, y: 371)); line.stroke()
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
