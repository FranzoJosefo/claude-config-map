// Draws the app icon (stacked level cards joined by an "applies to" line) as a 1024px PNG.
// Usage: swift tools/make-icon.swift out.png
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: ~824px rounded square centred in 1024.
let inset = 100.0
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x262522)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0x34322e), rgb(0x1c1b19)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
ctx.restoreGState()

// Level cards, widest (top) to narrowest (bottom), each shifted right.
let colors: [UInt32] = [0x8b5cf6, 0x2f7de1, 0x1f9d55, 0xd48806]
let cardH = 112.0, gap = 44.0
let startY = size / 2 + 1.5 * (cardH + gap) - cardH / 2
var centers: [CGPoint] = []
for (i, c) in colors.enumerated() {
    let x = 290.0 + Double(i) * 66.0
    let w = 520.0 - Double(i) * 66.0
    let y = startY - Double(i) * (cardH + gap)
    let r = CGRect(x: x, y: y, width: w, height: cardH)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.setFillColor(rgb(c)); ctx.fillPath()
    // text-ish lines on the card
    ctx.setFillColor(rgb(0xffffff, 0.55))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x + 40, y: y + cardH / 2 - 11, width: w * 0.45, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.fillPath()
    centers.append(CGPoint(x: x - 2, y: y + cardH / 2))
}
// "applies to" connector on the left
ctx.setStrokeColor(rgb(0xece9e2, 0.9)); ctx.setLineWidth(16); ctx.setLineCap(.round)
let lx = 228.0
ctx.move(to: CGPoint(x: lx, y: centers[0].y)); ctx.addLine(to: CGPoint(x: lx, y: centers.last!.y)); ctx.strokePath()
for p in centers {
    ctx.move(to: CGPoint(x: lx, y: p.y)); ctx.addLine(to: CGPoint(x: p.x - 18, y: p.y)); ctx.strokePath()
    ctx.setFillColor(rgb(0xece9e2)); ctx.fillEllipse(in: CGRect(x: lx - 20, y: p.y - 20, width: 40, height: 40))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
