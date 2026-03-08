#!/usr/bin/env swift
import Cocoa

// Lightning bolt path (normalized to 0–1 coordinate space)
func boltPath(in rect: CGRect, inset: CGFloat) -> NSBezierPath {
    let r = rect.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath()
    // Classic lightning bolt shape
    path.move(to: NSPoint(x: r.minX + r.width * 0.55, y: r.maxY))          // top
    path.line(to: NSPoint(x: r.minX + r.width * 0.25, y: r.midY + r.height * 0.05))
    path.line(to: NSPoint(x: r.minX + r.width * 0.47, y: r.midY + r.height * 0.05))
    path.line(to: NSPoint(x: r.minX + r.width * 0.40, y: r.minY))          // bottom
    path.line(to: NSPoint(x: r.minX + r.width * 0.75, y: r.midY - r.height * 0.05))
    path.line(to: NSPoint(x: r.minX + r.width * 0.53, y: r.midY - r.height * 0.05))
    path.close()
    return path
}

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // Dark background with rounded corners
    let corner = s * 0.22
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.02, dy: s * 0.02), xRadius: corner, yRadius: corner)

    // Gradient background: dark charcoal
    let bgColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
    bgColor.setFill()
    bg.fill()

    // Subtle border
    let borderColor = NSColor(white: 0.25, alpha: 0.6)
    borderColor.setStroke()
    bg.lineWidth = s * 0.01
    bg.stroke()

    // Lightning bolt - amber/orange gradient
    let bolt = boltPath(in: rect, inset: s * 0.18)

    // Glow effect
    let glowColor = NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 0.3)
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.setShadow(offset: .zero, blur: s * 0.08, color: glowColor.cgColor)
    let amberColor = NSColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 1.0)
    amberColor.setFill()
    bolt.fill()
    context.restoreGState()

    // Bolt fill on top (crisp)
    amberColor.setFill()
    bolt.fill()

    image.unlockFocus()
    return image
}

// Generate iconset
let iconsetPath = "/tmp/ClaudeUsageBar.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for entry in sizes {
    let image = generateIcon(size: entry.px)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to generate \(entry.name)")
    }
    let path = "\(iconsetPath)/\(entry.name).png"
    try! png.write(to: URL(fileURLWithPath: path))
    print("  \(entry.name).png (\(entry.px)px)")
}

print("Iconset created at \(iconsetPath)")
