// Renders Resources/AppIcon.icns. Run: swift Tools/make_icon.swift
import AppKit

let canvas: CGFloat = 1024

func render(size: Int) -> Data {
    let s = CGFloat(size) / canvas
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) in CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    // Squircle background on Apple's 824pt icon grid, with drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0.2, 0.2, 0.5, 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0.40, 0.30, 0.95, 1), rgb(0.10, 0.62, 0.95, 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // Soft top highlight.
    let gloss = CGGradient(colorsSpace: nil, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let white = rgb(1, 1, 1, 1)

    // Two circular arrows around the mouse: the "reverse" ring.
    let radius: CGFloat = 300, lineWidth: CGFloat = 46
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0.2, 0.3))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil) // one shadow for arcs + heads, no seams
    ctx.setStrokeColor(white); ctx.setFillColor(white)
    ctx.setLineWidth(lineWidth); ctx.setLineCap(.butt)
    for startDeg in [CGFloat(110), 290] {
        let a0 = startDeg * .pi / 180, a1 = (startDeg + 112) * .pi / 180
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.strokePath()
        let tail = CGPoint(x: center.x + radius * cos(a0), y: center.y + radius * sin(a0))
        ctx.fillEllipse(in: CGRect(x: tail.x - lineWidth / 2, y: tail.y - lineWidth / 2, width: lineWidth, height: lineWidth))
        // Arrowhead whose base sits on the arc end, tip continuing along the curve.
        let len: CGFloat = 110, half: CGFloat = 70
        let base = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
        let normal = CGPoint(x: cos(a1), y: sin(a1))
        let aTip = a1 + len / radius
        let tip = CGPoint(x: center.x + radius * cos(aTip), y: center.y + radius * sin(aTip))
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: base.x + normal.x * half, y: base.y + normal.y * half))
        ctx.addLine(to: CGPoint(x: base.x - normal.x * half, y: base.y - normal.y * half))
        ctx.closePath(); ctx.fillPath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Mouse body.
    let body = CGRect(x: 512 - 115, y: 512 - 180, width: 230, height: 360)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 115, cornerHeight: 115, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0, 0, 0.2, 0.35))
    ctx.addPath(bodyPath); ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let shade = CGGradient(colorsSpace: nil, colors: [rgb(1, 1, 1, 0), rgb(0.75, 0.8, 0.95, 0.6)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.restoreGState()

    // Button split and scroll wheel.
    ctx.setStrokeColor(rgb(0.35, 0.40, 0.75, 0.45)); ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: 512, y: body.maxY - 4)); ctx.addLine(to: CGPoint(x: 512, y: 600)); ctx.strokePath()
    ctx.move(to: CGPoint(x: body.minX + 6, y: 560)); ctx.addLine(to: CGPoint(x: body.maxX - 6, y: 560)); ctx.strokePath()
    let wheel = CGRect(x: 512 - 20, y: 600, width: 40, height: 80)
    ctx.addPath(CGPath(roundedRect: wheel, cornerWidth: 20, cornerHeight: 20, transform: nil))
    let wheelGrad = CGGradient(colorsSpace: nil, colors: [rgb(0.40, 0.30, 0.95, 1), rgb(0.10, 0.62, 0.95, 1)] as CFArray,
                               locations: [0, 1])!
    ctx.saveGState(); ctx.clip()
    ctx.drawLinearGradient(wheelGrad, start: CGPoint(x: 512, y: wheel.maxY), end: CGPoint(x: 512, y: wheel.minY), options: [])
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: root.appendingPathComponent("build/AppIcon-preview.png"))

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
