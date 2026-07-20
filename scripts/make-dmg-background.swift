#!/usr/bin/env swift
//
// make-dmg-background.swift — render the WP Container DMG install backdrop.
//
// Usage:
//   swift scripts/make-dmg-background.swift <out.png> <out@2x.png>
//
// Renders the "drag to Applications" backdrop entirely in code (CoreGraphics +
// CoreText) so it is reproducible and reviewable — no opaque binary blob. Two
// files are written: a @1x (640×400) and a @2x (1280×800) so the picture is
// crisp on Retina. The layout leaves empty space on the left (the real app
// icon) and right (the Applications alias) where Finder draws the actual icons
// on top; only the title, subtitle, and the connecting arrow are baked in.
//
// Design language mirrors the app: near-black window chrome (#161820) with a
// subtle vertical gradient, a faint blueprint grid echoing the app icon, and a
// WordPress-blue (#2679BA) accent arrow with a soft glow.

import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// ---- canvas geometry (points; @1x pixels) -----------------------------------
let W: CGFloat = 640
let H: CGFloat = 400

// Icon centres, in TOP-LEFT origin coordinates (matches the AppleScript
// `set position` space Finder uses). Keep these in sync with release.sh.
let iconY: CGFloat = 200          // vertical centre of both icons
let appX: CGFloat = 160           // left: the app
let appsX: CGFloat = 480          // right: the /Applications alias
let iconHalf: CGFloat = 56        // half of the ~112px icon box

// ---- colour helpers ----------------------------------------------------------
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// Convert a top-left-origin y to CoreGraphics' bottom-left-origin y.
func cgY(_ topY: CGFloat) -> CGFloat { H - topY }

// ---- text --------------------------------------------------------------------
func drawCenteredText(_ ctx: CGContext, _ string: String, font: CTFont,
                      color: CGColor, centerX: CGFloat, baselineTopY: CGFloat,
                      tracking: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: tracking,
    ]
    let attr = NSAttributedString(string: string, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let x = centerX - bounds.width / 2 - bounds.origin.x
    ctx.textPosition = CGPoint(x: x, y: cgY(baselineTopY))
    CTLineDraw(line, ctx)
}

// ---- the picture -------------------------------------------------------------
func render(scale: CGFloat) -> CGImage {
    let pxW = Int(W * scale), pxH = Int(H * scale)
    let ctx = CGContext(data: nil, width: pxW, height: pxH,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)   // draw everything in 640×400 point space
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 1) vertical gradient background (#191B21 top → #14151B bottom)
    let bg = CGGradient(colorsSpace: cs,
                        colors: [rgb(25, 27, 33), rgb(20, 21, 27)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H),
                           end: CGPoint(x: 0, y: 0), options: [])

    // 2) faint blueprint grid (echoes the app icon), very low alpha
    ctx.saveGState()
    ctx.setStrokeColor(rgb(38, 121, 186, 0.05))
    ctx.setLineWidth(1)
    let step: CGFloat = 40
    var gx: CGFloat = step
    while gx < W { ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: H)); gx += step }
    var gy: CGFloat = step
    while gy < H { ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: W, y: gy)); gy += step }
    ctx.strokePath()
    ctx.restoreGState()

    // 3) soft blue glow behind the arrow, centred between the icons
    let glowCenter = CGPoint(x: (appX + appsX) / 2, y: cgY(iconY))
    let glow = CGGradient(colorsSpace: cs,
                          colors: [rgb(38, 121, 186, 0.22), rgb(38, 121, 186, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                           endCenter: glowCenter, endRadius: 150, options: [])

    // 4) the connecting arrow (left → right), sitting in the gap between icons
    let yc = cgY(iconY)
    let shaftStart = appX + iconHalf + 26      // clear of the app icon box
    let shaftEnd   = appsX - iconHalf - 26     // clear of the Applications box
    let headLen: CGFloat = 20
    let headHalf: CGFloat = 15

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 12 * scale, color: rgb(38, 121, 186, 0.55))
    ctx.setStrokeColor(rgb(74, 158, 224).copy(alpha: 1)!)   // bright WP blue
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // shaft
    ctx.move(to: CGPoint(x: shaftStart, y: yc))
    ctx.addLine(to: CGPoint(x: shaftEnd, y: yc))
    // arrowhead
    ctx.move(to: CGPoint(x: shaftEnd - headLen, y: yc + headHalf))
    ctx.addLine(to: CGPoint(x: shaftEnd, y: yc))
    ctx.addLine(to: CGPoint(x: shaftEnd - headLen, y: yc - headHalf))
    ctx.strokePath()
    ctx.restoreGState()

    // 5) title + subtitle (light on dark). Uses the platform system UI font
    // (SF Pro on macOS) so the script needs no bundled font file.
    drawCenteredText(ctx, "WP Container", font: uiFont(30, bold: true),
                     color: rgb(242, 245, 250), centerX: W / 2,
                     baselineTopY: 74, tracking: 0.3)
    drawCenteredText(ctx, "Drag to Applications to install", font: uiFont(14, bold: false),
                     color: rgb(132, 141, 158), centerX: W / 2,
                     baselineTopY: 104, tracking: 0.2)

    return ctx.makeImage()!
}

// Reliable system-font builder — SF Pro is the system UI font on macOS.
func uiFont(_ size: CGFloat, bold: Bool) -> CTFont {
    CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
}

// ---- write PNG ---------------------------------------------------------------
func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("failed to create PNG destination for \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("failed to write \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

// ---- main --------------------------------------------------------------------
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: swift make-dmg-background.swift <out.png> <out@2x.png>\n".data(using: .utf8)!)
    exit(2)
}
let out1x = args[1]
let out2x = args[2]

for p in [out1x, out2x] {
    let dir = (p as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
}

writePNG(render(scale: 1), to: out1x)
writePNG(render(scale: 2), to: out2x)
print("wrote \(out1x) (640×400) and \(out2x) (1280×800)")
