#!/usr/bin/env swift

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL = root.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedPath(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(
        roundedRect: NSRect(x: x, y: y, width: width, height: height),
        xRadius: radius,
        yRadius: radius
    )
}

func fill(_ path: NSBezierPath, _ fillColor: NSColor) {
    fillColor.setFill()
    path.fill()
}

func stroke(_ path: NSBezierPath, _ strokeColor: NSColor, width: CGFloat, lineCap: NSBezierPath.LineCapStyle = .round) {
    strokeColor.setStroke()
    path.lineWidth = width
    path.lineCapStyle = lineCap
    path.stroke()
}

func drawArrow(from start: CGPoint, to end: CGPoint, color arrowColor: NSColor) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    stroke(path, arrowColor, width: 44)

    let angle = atan2(end.y - start.y, end.x - start.x)
    let length: CGFloat = 86
    let spread: CGFloat = .pi / 6
    let p1 = CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread))
    let p2 = CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))
    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: p1)
    head.line(to: p2)
    head.close()
    fill(head, arrowColor)
}

func drawLine(y: CGFloat, width: CGFloat, alpha: CGFloat = 1) {
    let line = roundedPath(x: 342, y: y, width: width, height: 30, radius: 15)
    fill(line, color(38, 92, 150, alpha))
}

func renderIcon(pixelSize: Int) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create \(pixelSize)px bitmap"])
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }

    let context = graphicsContext.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let scale = CGFloat(pixelSize) / 1024
    context.scaleBy(x: scale, y: scale)

    let background = roundedPath(x: 64, y: 64, width: 896, height: 896, radius: 208)
    background.addClip()
    NSGradient(colors: [
        color(24, 88, 197),
        color(18, 146, 207),
        color(88, 212, 194)
    ])?.draw(in: background, angle: 315)

    fill(roundedPath(x: 96, y: 650, width: 310, height: 90, radius: 45), color(255, 255, 255, 0.12))
    fill(roundedPath(x: 612, y: 254, width: 310, height: 90, radius: 45), color(255, 255, 255, 0.10))

    NSGraphicsContext.saveGraphicsState()
    let backShadow = NSShadow()
    backShadow.shadowBlurRadius = 18
    backShadow.shadowOffset = NSSize(width: 0, height: -8)
    backShadow.shadowColor = color(8, 32, 74, 0.24)
    backShadow.set()
    fill(roundedPath(x: 250, y: 250, width: 464, height: 560, radius: 48), color(207, 236, 255, 0.74))
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let frontShadow = NSShadow()
    frontShadow.shadowBlurRadius = 36
    frontShadow.shadowOffset = NSSize(width: 0, height: -14)
    frontShadow.shadowColor = color(7, 25, 62, 0.34)
    frontShadow.set()
    fill(roundedPath(x: 318, y: 206, width: 462, height: 612, radius: 52), color(248, 253, 255))
    NSGraphicsContext.restoreGraphicsState()

    let fold = NSBezierPath()
    fold.move(to: CGPoint(x: 650, y: 818))
    fold.line(to: CGPoint(x: 780, y: 688))
    fold.line(to: CGPoint(x: 780, y: 818))
    fold.close()
    fill(fold, color(197, 229, 249))

    stroke(roundedPath(x: 318, y: 206, width: 462, height: 612, radius: 52), color(255, 255, 255, 0.74), width: 4)
    drawLine(y: 622, width: 216, alpha: 0.42)
    drawLine(y: 566, width: 312, alpha: 0.30)
    drawLine(y: 510, width: 240, alpha: 0.24)

    drawArrow(from: CGPoint(x: 420, y: 416), to: CGPoint(x: 640, y: 416), color: color(22, 139, 217))
    drawArrow(from: CGPoint(x: 656, y: 340), to: CGPoint(x: 436, y: 340), color: color(73, 191, 172))

    let seal = roundedPath(x: 404, y: 676, width: 158, height: 62, radius: 24)
    fill(seal, color(232, 67, 74))
    fill(roundedPath(x: 434, y: 700, width: 98, height: 14, radius: 7), color(255, 255, 255, 0.88))

    return rep
}

func writePNG(pixelSize: Int, name: String) throws {
    let rep = try renderIcon(pixelSize: pixelSize)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(name)"])
    }
    try png.write(to: iconsetURL.appendingPathComponent(name))
}

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for entry in entries {
    try writePNG(pixelSize: entry.0, name: entry.1)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "AppIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print("Generated \(icnsURL.path)")
