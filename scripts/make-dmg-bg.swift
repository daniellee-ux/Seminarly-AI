// make-dmg-bg.swift — render the DMG window background (660x400 @2x = 1320x800):
// cream paper gradient, a serif "Drag Seminarly into Applications" line, and a
// terracotta arrow pointing from the app toward the Applications folder.
//
//   swift make-dmg-bg.swift <output.png>

import CoreGraphics
import CoreText
import ImageIO
import Foundation
import UniformTypeIdentifiers

let cs = CGColorSpaceCreateDeviceRGB()
func col(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r)/255, CGFloat(g)/255, CGFloat(b)/255, a])!
}

let W = 1320, H = 800
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high

// cream paper gradient
let g = CGGradient(colorsSpace: cs, colors: [col(251, 244, 232), col(242, 230, 210)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// instruction line (Georgia ≈ the site's serif), muted ink, near the top
func centeredText(_ s: String, _ size: CGFloat, _ color: CGColor, _ cx: CGFloat, _ baselineFromTop: CGFloat, _ fontName: String) {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: cx - b.width/2, y: CGFloat(H) - baselineFromTop)
    CTLineDraw(line, ctx)
}
centeredText("Drag Seminarly into Applications", 42, col(90, 74, 58), CGFloat(W)/2, 150, "Georgia")

// terracotta arrow at vertical centre, pointing right (app → Applications)
let cy = CGFloat(H)/2 - 20
let x1: CGFloat = 565, x2: CGFloat = 755
ctx.setStrokeColor(col(193, 74, 31, 0.85)); ctx.setLineWidth(11); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: x1, y: cy)); ctx.addLine(to: CGPoint(x: x2, y: cy)); ctx.strokePath()
ctx.setFillColor(col(193, 74, 31, 0.85))
ctx.move(to: CGPoint(x: x2 + 34, y: cy))
ctx.addLine(to: CGPoint(x: x2 - 14, y: cy + 28))
ctx.addLine(to: CGPoint(x: x2 - 14, y: cy - 28))
ctx.closePath(); ctx.fillPath()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-bg.png"
if let img = ctx.makeImage(),
   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out)")
}
