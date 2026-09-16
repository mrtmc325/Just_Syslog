// Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
//
// Renders the app icon (1024x1024 PNG) — a white broadcast glyph on a dark
// slate rounded square, matching the menu bar symbol. AppKit only.
// Usage: swiftc make-icon.swift -o makeicon -framework AppKit && ./makeicon out.png

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// Rounded-square background with a vertical slate gradient.
let margin = S * 0.085
let bg = NSRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let path = NSBezierPath(roundedRect: bg, xRadius: bg.width * 0.224, yRadius: bg.width * 0.224)
NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.28, alpha: 1),
    NSColor(srgbRed: 0.09, green: 0.11, blue: 0.16, alpha: 1),
])!.draw(in: path, angle: -90)

// White SF Symbol glyph, centered.
let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.42, weight: .semibold)
if let base = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil),
   let sym = base.withSymbolConfiguration(cfg) {
    let g = sym.size
    let white = NSImage(size: g)
    white.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: g).fill()
    sym.draw(at: .zero, from: NSRect(origin: .zero, size: g), operation: .destinationIn, fraction: 1)
    white.unlockFocus()
    white.draw(in: NSRect(x: (S - g.width) / 2, y: (S - g.height) / 2, width: g.width, height: g.height))
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon encode failed\n".data(using: .utf8)!)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
