// Renders BTSwitch's app icon and packs it into BTSwitch/AppIcon.icns.
//
//     swift scripts/make-icon.swift
//
// Drawn with Core Graphics (no SF Symbols — their license excludes app
// icons). Follows the macOS icon grid: an 824pt rounded square centred on a
// 1024pt canvas, leaving room for the drop shadow.

import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// One horizontal arrow: shaft plus triangular head. y is the centre line.
func arrow(_ ctx: CGContext, fromX: CGFloat, toX: CGFloat, y: CGFloat, thickness: CGFloat, head: CGFloat) {
    let dir: CGFloat = toX > fromX ? 1 : -1
    let shaftEnd = toX - dir * head * 0.9
    ctx.addPath(roundedRect(CGRect(x: min(fromX, shaftEnd), y: y - thickness / 2,
                                   width: abs(shaftEnd - fromX), height: thickness), thickness / 2))
    ctx.fillPath()
    ctx.move(to: CGPoint(x: toX, y: y))
    ctx.addLine(to: CGPoint(x: toX - dir * head, y: y + head * 0.62))
    ctx.addLine(to: CGPoint(x: toX - dir * head, y: y - head * 0.62))
    ctx.closePath()
    ctx.fillPath()
}

func draw(_ ctx: CGContext) {
    // Background tile with shadow and vertical gradient.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x2F6BE0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x5AA2FF), color(0x1F4FC4)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // Soft highlight across the top half.
    ctx.setFillColor(color(0xFFFFFF, 0.06))
    ctx.fillEllipse(in: CGRect(x: tile.minX - 200, y: tile.midY + 40, width: tile.width + 400, height: 700))
    ctx.restoreGState()

    // Two-way arrow (switching between Macs).
    ctx.setFillColor(color(0xFFFFFF))
    arrow(ctx, fromX: 330, toX: 694, y: 712, thickness: 44, head: 92)
    arrow(ctx, fromX: 694, toX: 330, y: 592, thickness: 44, head: 92)

    // Keyboard body.
    let kb = CGRect(x: 232, y: 228, width: 560, height: 272)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x0A2A6B, 0.45))
    ctx.addPath(roundedRect(kb, 44))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Keys: three rows of keys and a space bar.
    ctx.setFillColor(color(0x2F6BE0, 0.85))
    let pad: CGFloat = 34, gap: CGFloat = 14, keyH: CGFloat = 40
    let innerW = kb.width - pad * 2
    for (row, count) in [10, 9, 8].enumerated() {
        let keyW = (innerW - gap * CGFloat(9)) / 10
        let rowW = keyW * CGFloat(count) + gap * CGFloat(count - 1)
        let x0 = kb.minX + (kb.width - rowW) / 2
        let y = kb.maxY - pad - keyH - CGFloat(row) * (keyH + gap)
        for i in 0..<count {
            ctx.addPath(roundedRect(CGRect(x: x0 + CGFloat(i) * (keyW + gap), y: y, width: keyW, height: keyH), 9))
        }
        ctx.fillPath()
    }
    let spaceY = kb.maxY - pad - keyH - 3 * (keyH + gap)
    ctx.addPath(roundedRect(CGRect(x: kb.midX - 150, y: spaceY, width: 300, height: keyH), 9))
    ctx.fillPath()
}

func png(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(px) / canvas, y: CGFloat(px) / canvas)
    draw(ctx)
    gctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let output = root.appendingPathComponent("BTSwitch/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }

// Also keep a PNG preview for the README.
try png(size: 512).write(to: root.appendingPathComponent("docs/icon.png"))
print("wrote \(output.path)")
