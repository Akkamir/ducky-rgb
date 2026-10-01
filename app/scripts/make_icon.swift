// Draws the Ducky RGB app icon, a lit rainbow keyboard, as a 1024 x 1024 PNG.
// Usage: swift make_icon.swift <output.png>   (scripts/bundle.sh turns it into AppIcon.icns)
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func hue(_ h: CGFloat) -> CGColor {
    NSColor(calibratedHue: h.truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1, alpha: 1).cgColor
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: an 824 pt body centred in 1024.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x15171c))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let background = CGGradient(colorsSpace: space, colors: [rgb(0x262a33), rgb(0x0c0d10)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

/// A glowing keycap with a lighter top face.
func key(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 18) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
    let face = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12).offsetBy(dx: 0, dy: rect.height * 0.05)
    ctx.addPath(CGPath(roundedRect: face, cornerWidth: radius * 0.6, cornerHeight: radius * 0.6, transform: nil))
    ctx.setFillColor(rgb(0xffffff, 0.18))
    ctx.fillPath()
}

// Five staggered rows with a space bar, rainbow across.
let rows: [(offset: CGFloat, count: Int)] = [(0, 8), (22, 8), (32, 8), (48, 7), (0, 5)]
let unit: CGFloat = 78, gap: CGFloat = 12
let width = 8 * unit + 7 * gap
let left = (size - width - 32) / 2 // the most staggered row sticks out by 32
for (r, row) in rows.enumerated() {
    let y = 653 - CGFloat(r) * (unit + gap)
    var x = left + row.offset
    for k in 0..<row.count {
        let w = r == 4 && k == 2 ? unit * 3 + gap * 2 : unit
        key(CGRect(x: x, y: y, width: w, height: unit), hue(0.52 + (x - left) / width * 0.75))
        x += w + gap
    }
}
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
