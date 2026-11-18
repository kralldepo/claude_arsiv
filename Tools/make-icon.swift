// Draws the app icon as a 1024×1024 PNG.  Usage: swift Tools/make-icon.swift out.png
import AppKit

let canvas = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824-point rounded tile centred on the 1024 canvas.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

let top = NSColor(calibratedRed: 0.27, green: 0.80, blue: 0.86, alpha: 1)
let bottom = NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.92, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: -90)

func drawSymbol(_ name: String, pointSize: CGFloat, center: NSPoint, color: NSColor) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let size = image.size
    image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height))
}

drawSymbol("bubble.left.and.bubble.right.fill", pointSize: 360, center: NSPoint(x: 492, y: 482), color: .white)
drawSymbol("sparkles", pointSize: 150, center: NSPoint(x: 748, y: 744),
           color: NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.55, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
