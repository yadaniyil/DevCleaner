// Renders the 1024×1024 master for AppIcon.icns: a macOS-style rounded square with a
// gradient behind the same internaldrive symbol the menu bar item shows, so the Dock
// tile and the menu bar read as one app. Run by make-app.sh; takes the output PNG path.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift make-icon.swift <out.png>\n".utf8))
    exit(64)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Apple's icon grid: the rounded square fills ~824 of the 1024 canvas, corners ~185.
let inset: CGFloat = 100
let square = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let path = NSBezierPath(roundedRect: square, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(calibratedRed: 0.32, green: 0.58, blue: 0.92, alpha: 1),
    ending: NSColor(calibratedRed: 0.09, green: 0.20, blue: 0.45, alpha: 1))!
    .draw(in: path, angle: -90)

let configuration = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
if let symbol = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    // Re-tint to white: template images draw black outside of AppKit controls.
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(
        x: (canvas - tinted.size.width) / 2,
        y: (canvas - tinted.size.height) / 2,
        width: tinted.size.width,
        height: tinted.size.height))
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the icon PNG.\n".utf8))
    exit(1)
}
try png.write(to: outputURL)
