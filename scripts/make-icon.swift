// make-icon.swift — render the Seminarly macOS app icon at every required size.
// A terracotta "squircle" (rounded-rect on the standard macOS grid: 824/1024 body,
// 185 corner radius, transparent margins) with a cream audio waveform.
//
//   swift make-icon.swift <output-dir>
//
// Writes AppIcon-{16,32,64,128,256,512,1024}.png.

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let cs = CGColorSpaceCreateDeviceRGB()
func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r)/255, CGFloat(g)/255, CGFloat(b)/255, a])!
}

func render(_ N: Int, to path: String) {
    let s = CGFloat(N) / 1024.0
    guard let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // macOS icon grid: 824x824 body inside 1024, ~100 margin, 185 corner radius.
    let inset: CGFloat = 100 * s
    let body = CGRect(x: inset, y: inset, width: CGFloat(N) - 2*inset, height: CGFloat(N) - 2*inset)
    let radius: CGFloat = 185 * s
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // soft drop shadow under the squircle (the "sits on the surface" depth other icons have)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s, color: c(60, 24, 10, 0.30))
    ctx.addPath(squircle); ctx.setFillColor(c(150, 52, 22)); ctx.fillPath()
    ctx.restoreGState()

    // terracotta gradient fill, clipped to the squircle
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [c(201, 82, 33), c(150, 52, 22)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(N)), end: CGPoint(x: 0, y: 0), options: [])
    // gentle top-left sheen
    let sheen = CGGradient(colorsSpace: cs, colors: [c(255, 190, 140, 0.22), c(255, 190, 140, 0)] as CFArray, locations: [0, 1])!
    let hp = CGPoint(x: body.minX + body.width*0.32, y: body.maxY - body.height*0.16)
    ctx.drawRadialGradient(sheen, startCenter: hp, startRadius: 0, endCenter: hp, endRadius: body.width*0.72, options: [])
    ctx.restoreGState()

    // cream waveform — 9 rounded bars, varied heights, centered
    let heights: [CGFloat] = [0.34, 0.58, 0.82, 0.62, 1.00, 0.70, 0.88, 0.52, 0.36]
    let barW: CGFloat = 46 * s, gap: CGFloat = 30 * s, maxH: CGFloat = 460 * s
    let totalW = CGFloat(heights.count)*barW + CGFloat(heights.count - 1)*gap
    var x = (CGFloat(N) - totalW) / 2
    let cy = CGFloat(N) / 2
    ctx.setFillColor(c(247, 241, 231))
    for f in heights {
        let h = max(f * maxH, barW)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: cy - h/2, width: barW, height: h),
                           cornerWidth: barW/2, cornerHeight: barW/2, transform: nil))
        x += barW + gap
    }
    ctx.fillPath()

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path) (\(N)px)")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for n in [16, 32, 64, 128, 256, 512, 1024] { render(n, to: "\(outDir)/AppIcon-\(n).png") }
