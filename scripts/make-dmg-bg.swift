// make-dmg-bg.swift — render the DMG installer window background.
//
// The Finder window is 660x400 pt (see dmg-settings.py). We render at 2x
// (1320x800 px) for Retina sharpness and tag the PNG at 144 DPI so macOS maps the
// pixels back to 660x400 pt. That tag is essential: Finder draws a DMG background
// at 1 px = 1 pt, so an untagged 1320x800 image is shown cropped to its top-left
// 660x400 — which is what clipped the headline to "Drag Seminarly i" and pushed
// the arrow off-screen. All layout below is authored in points (top-left origin,
// y down) and aligned to the icon centers from dmg-settings.py.
//
//   swift make-dmg-bg.swift <output.png>

import CoreGraphics
import CoreText
import ImageIO
import Foundation
import UniformTypeIdentifiers

let scale: CGFloat = 2
let Wpt: CGFloat = 660, Hpt: CGFloat = 400
let W = Int(Wpt * scale), H = Int(Hpt * scale)   // 1320 x 800

// Icon geometry mirrors dmg-settings.py (128pt icons centered at these points).
let iconCenterY: CGFloat = 200
let appCenterX: CGFloat = 180
let appsCenterX: CGFloat = 480
let iconHalf: CGFloat = 64

let cs = CGColorSpaceCreateDeviceRGB()
func col(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r)/255, CGFloat(g)/255, CGFloat(b)/255, a])!
}

guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)

// pt → px; topPt → CoreGraphics y (bottom-left origin).
func px(_ pt: CGFloat) -> CGFloat { pt * scale }
func yUp(_ topPt: CGFloat) -> CGFloat { CGFloat(H) - topPt * scale }

// --- cream paper gradient (brand: Braun/Rams warm paper) ----------------------
let g = CGGradient(colorsSpace: cs, colors: [col(252, 246, 236), col(240, 228, 208)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// --- serif instruction line, centered above the icons -------------------------
func centeredText(_ s: String, sizePt: CGFloat, color: CGColor, centerXPt: CGFloat, baselineTopPt: CGFloat, font fontName: String) {
    let font = CTFontCreateWithName(fontName as CFString, sizePt * scale, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .init(kCTFontAttributeName as String): font,
        .init(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: px(centerXPt) - b.width / 2, y: yUp(baselineTopPt))
    CTLineDraw(line, ctx)
}
centeredText("Drag Seminarly into Applications", sizePt: 21, color: col(74, 61, 48),
             centerXPt: Wpt / 2, baselineTopPt: 92, font: "Georgia")

// --- terracotta arrow, centered in the gap between the two icons --------------
let arrowY = yUp(iconCenterY)
let gapStart = appCenterX + iconHalf        // right edge of the app icon
let gapEnd = appsCenterX - iconHalf         // left edge of the Applications icon
let shaftLeft = px(gapStart + 22)
let shaftRight = px(gapEnd - 30)            // leave room for the head
let terracotta = col(193, 74, 31, 0.92)
ctx.setStrokeColor(terracotta); ctx.setLineWidth(5 * scale); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: shaftLeft, y: arrowY)); ctx.addLine(to: CGPoint(x: shaftRight, y: arrowY)); ctx.strokePath()
ctx.setFillColor(terracotta)
let head: CGFloat = 14 * scale
ctx.move(to: CGPoint(x: shaftRight + head, y: arrowY))
ctx.addLine(to: CGPoint(x: shaftRight - head * 0.35, y: arrowY + head))
ctx.addLine(to: CGPoint(x: shaftRight - head * 0.35, y: arrowY - head))
ctx.closePath(); ctx.fillPath()

// --- write PNG tagged @144 DPI so it lays out at 660x400 pt -------------------
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-bg.png"
if let img = ctx.makeImage(),
   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil) {
    let dpi = 72 * scale
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    print("wrote \(out) (\(W)x\(H) @ \(Int(dpi))dpi → \(Int(Wpt))x\(Int(Hpt))pt)")
}
