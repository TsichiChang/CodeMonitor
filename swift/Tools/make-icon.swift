import AppKit
import CoreGraphics
import Foundation

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard
  let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("context") }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(
    red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// ── Body: a rounded square, inset the way macOS icon art usually is ──
let inset: CGFloat = 96
let body = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 200, cornerHeight: 200, transform: nil)

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(
  colorsSpace: cs, colors: [rgb(0x33333A), rgb(0x1A1A1E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
  bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY),
  options: [])
ctx.restoreGState()

// Hairline rim, so the body reads as a surface rather than a flat fill.
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
ctx.setLineWidth(4)
ctx.strokePath()

// ── Three rows: one per session state ──
let pad: CGFloat = 104
let area = body.insetBy(dx: pad, dy: pad)
let gap: CGFloat = 42
let rowH = (area.height - gap * 2) / 3

// Ordered as the dashboard orders them — most urgent on top.
let states: [(dot: UInt32, glow: CGFloat, bar: CGFloat)] = [
  (0xF5A623, 0.55, 0.62),  // waiting
  (0x34C759, 0.50, 0.38),  // running
  (0x585860, 0.00, 0.12),  // idle — deliberately dim (ADR-0007)
]

for (index, state) in states.enumerated() {
  let y = area.maxY - rowH - CGFloat(index) * (rowH + gap)
  let row = CGRect(x: area.minX, y: y, width: area.width, height: rowH)

  // Slot
  let slot = CGPath(roundedRect: row, cornerWidth: rowH / 2.6, cornerHeight: rowH / 2.6, transform: nil)
  ctx.addPath(slot)
  ctx.setFillColor(rgb(0x000000, 0.22))
  ctx.fillPath()
  ctx.addPath(slot)
  ctx.setStrokeColor(rgb(0xFFFFFF, 0.05))
  ctx.setLineWidth(3)
  ctx.strokePath()

  // Indicator, with a glow for the states that are actually alive
  let r = rowH * 0.27
  let centre = CGPoint(x: row.minX + rowH * 0.52, y: row.midY)
  if state.glow > 0 {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 1.5, color: rgb(state.dot, state.glow))
    ctx.setFillColor(rgb(state.dot))
    ctx.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    ctx.restoreGState()
  }
  ctx.setFillColor(rgb(state.dot))
  ctx.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
  // Highlight so the dot reads as lit rather than painted
  ctx.setFillColor(rgb(0xFFFFFF, state.glow > 0 ? 0.32 : 0.10))
  ctx.fillEllipse(
    in: CGRect(x: centre.x - r * 0.42, y: centre.y + r * 0.06, width: r * 0.72, height: r * 0.62))

  // Label bar — length varies so the rows read as different sessions
  let barX = centre.x + r + rowH * 0.42
  let barW = (row.maxX - rowH * 0.5 - barX) * (0.34 + state.bar * 0.66)
  let barH = rowH * 0.19
  ctx.addPath(
    CGPath(
      roundedRect: CGRect(x: barX, y: row.midY - barH / 2, width: barW, height: barH),
      cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
  ctx.setFillColor(rgb(0xFFFFFF, state.glow > 0 ? 0.26 : 0.13))
  ctx.fillPath()
}

guard let image = ctx.makeImage() else { fatalError("image") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try data.write(to: out)
print("wrote \(out.path)")
