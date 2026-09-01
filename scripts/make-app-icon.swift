import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <output.png>\n".utf8))
    exit(64)
}

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor(calibratedRed: 0.035, green: 0.46, blue: 0.95, alpha: 1).setFill()
NSBezierPath(
    roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940),
    xRadius: 230,
    yRadius: 230
).fill()

let feather = NSBezierPath()
feather.move(to: NSPoint(x: 292, y: 283))
feather.curve(
    to: NSPoint(x: 770, y: 758),
    controlPoint1: NSPoint(x: 405, y: 620),
    controlPoint2: NSPoint(x: 614, y: 835)
)
feather.curve(
    to: NSPoint(x: 282, y: 374),
    controlPoint1: NSPoint(x: 600, y: 800),
    controlPoint2: NSPoint(x: 360, y: 654)
)
feather.curve(
    to: NSPoint(x: 292, y: 283),
    controlPoint1: NSPoint(x: 273, y: 339),
    controlPoint2: NSPoint(x: 276, y: 305)
)
feather.close()
NSColor.white.setFill()
feather.fill()

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 242, y: 214))
shaft.line(to: NSPoint(x: 724, y: 703))
shaft.lineWidth = 44
shaft.lineCapStyle = .round
NSColor.white.setStroke()
shaft.stroke()

for (start, end) in [
    (NSPoint(x: 436, y: 496), NSPoint(x: 668, y: 496)),
    (NSPoint(x: 362, y: 414), NSPoint(x: 559, y: 414)),
] {
    let barb = NSBezierPath()
    barb.move(to: start)
    barb.line(to: end)
    barb.lineWidth = 34
    barb.lineCapStyle = .round
    barb.stroke()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("could not render app icon\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
