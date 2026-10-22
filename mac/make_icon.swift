// Draws the 1024 px DualDL app icon: two light streams (Ethernet, Wi-Fi)
// merging into one download arrow, on a macOS-grid squircle.
// usage: make_icon <out.png>
import AppKit
import CoreGraphics

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: stops)!
}

// Apple's macOS icon grid: 824 px body centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.32))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x0B1E5B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Background: deep blue to indigo, with a soft cyan glow where the streams meet
ctx.drawLinearGradient(gradient([rgb(0x2F7BFF), rgb(0x1A3FB8), rgb(0x0C1A52)], [0, 0.55, 1]),
                       start: CGPoint(x: 300, y: 924), end: CGPoint(x: 720, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.drawRadialGradient(gradient([rgb(0x64D2FF, 0.55), rgb(0x64D2FF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])

// One stream: a thick curve filled with a gradient that brightens toward the merge point
func stream(from start: CGPoint, c1: CGPoint, c2: CGPoint, top: CGColor) {
    let p = CGMutablePath()
    p.move(to: start)
    p.addCurve(to: CGPoint(x: 512, y: 520), control1: c1, control2: c2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: top.copy(alpha: 0.9))
    ctx.addPath(p)
    ctx.setLineWidth(70)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([top, rgb(0xFFFFFF)], [0, 1]),
                           start: CGPoint(x: 512, y: 860), end: CGPoint(x: 512, y: 520), options: [])
    ctx.restoreGState()
}

stream(from: CGPoint(x: 262, y: 820), c1: CGPoint(x: 262, y: 640), c2: CGPoint(x: 512, y: 700),
       top: rgb(0x5AC8FA))   // Ethernet
stream(from: CGPoint(x: 762, y: 820), c1: CGPoint(x: 762, y: 640), c2: CGPoint(x: 512, y: 700),
       top: rgb(0x30D158))   // Wi-Fi

// Merged shaft + arrow head
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x000000, 0.25))
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(70)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let shaft = CGMutablePath()
shaft.move(to: CGPoint(x: 512, y: 540))
shaft.addLine(to: CGPoint(x: 512, y: 330))
let head = CGMutablePath()
head.move(to: CGPoint(x: 392, y: 440))
head.addLine(to: CGPoint(x: 512, y: 318))
head.addLine(to: CGPoint(x: 632, y: 440))
ctx.addPath(shaft)
ctx.addPath(head)
ctx.strokePath()

// Tray
let tray = CGPath(roundedRect: CGRect(x: 318, y: 206, width: 388, height: 52),
                  cornerWidth: 26, cornerHeight: 26, transform: nil)
ctx.addPath(tray)
ctx.setFillColor(rgb(0xFFFFFF, 0.92))
ctx.fillPath()
ctx.restoreGState()

// Glass sheen on the upper half
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Hairline edge highlight
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
ctx.setLineWidth(4)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
