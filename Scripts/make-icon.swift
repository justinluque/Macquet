#!/usr/bin/env swift
//
// Draws Macquet's app icon: a parquet floor, in basket-weave blocks, with one
// block lit up the way a selected cell is. Run it to regenerate Macquet.icns.
//
//   swift Scripts/make-icon.swift Resources
//

import AppKit
import CoreGraphics
import Foundation

let side = 1024
let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")

// MARK: - Palette

struct RGB {
    let r: Double, g: Double, b: Double
    func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: alpha)
    }
    func shaded(_ amount: Double) -> RGB {
        RGB(r: min(1, r * amount), g: min(1, g * amount), b: min(1, b * amount))
    }
}

let woodLight = RGB(r: 0.85, g: 0.63, b: 0.36)
let woodDark = RGB(r: 0.62, g: 0.40, b: 0.20)
let grout = RGB(r: 0.35, g: 0.21, b: 0.10)
let highlight = RGB(r: 0.25, g: 0.55, b: 0.96)

/// Stable pseudo-random in 0..<1 so the icon is byte-identical every run.
func noise(_ a: Int, _ b: Int, _ c: Int) -> Double {
    var hash = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791))
    hash ^= hash >> 33
    hash = hash &* 0xff51_afd7_ed55_8ccd
    hash ^= hash >> 33
    return Double(hash % 10_000) / 10_000
}

// MARK: - Drawing

guard
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    fatalError("couldn't create bitmap context")
}

let size = Double(side)
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

// macOS icons sit inside a rounded square with breathing room around it.
let inset = size * 0.086
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius = plate.width * 0.2237

let plateShape = CGPath(
    roundedRect: plate, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Drop shadow, so the icon reads on both light and dark Finder backgrounds.
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.028,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
context.addPath(plateShape)
context.setFillColor(grout.cg())
context.fillPath()
context.restoreGState()

// Everything below is clipped to the plate.
context.saveGState()
context.addPath(plateShape)
context.clip()

context.setFillColor(grout.cg())
context.fill(plate)

// Basket-weave parquet: a grid of blocks, each block a set of parallel planks,
// with orientation alternating like a checkerboard.
let blocksPerSide = 3
let blockSize = plate.width / Double(blocksPerSide)
let planksPerBlock = 3
let gap = blockSize * 0.028

// The lit block — offset from centre so it reads as a highlighted cell.
let litRow = 1
let litColumn = 1

for row in 0..<blocksPerSide {
    for column in 0..<blocksPerSide {
        let origin = CGPoint(
            x: plate.minX + Double(column) * blockSize,
            y: plate.minY + Double(row) * blockSize)
        let horizontal = (row + column).isMultiple(of: 2)
        let isLit = row == litRow && column == litColumn
        let plankThickness = (blockSize - gap * Double(planksPerBlock + 1))
            / Double(planksPerBlock)

        for plank in 0..<planksPerBlock {
            let offset = gap + Double(plank) * (plankThickness + gap)
            let rect: CGRect
            if horizontal {
                rect = CGRect(
                    x: origin.x + gap, y: origin.y + offset,
                    width: blockSize - gap * 2, height: plankThickness)
            } else {
                rect = CGRect(
                    x: origin.x + offset, y: origin.y + gap,
                    width: plankThickness, height: blockSize - gap * 2)
            }

            let base = isLit ? highlight : woodLight
            // Blend each plank a little toward the darker tone for grain.
            let blend = noise(row, column, plank)
            let tone = RGB(
                r: base.r + (woodDark.r - base.r) * blend * (isLit ? 0.35 : 0.85),
                g: base.g + (woodDark.g - base.g) * blend * (isLit ? 0.35 : 0.85),
                b: base.b + (woodDark.b - base.b) * blend * (isLit ? 0.35 : 0.85))

            let plankPath = CGPath(
                roundedRect: rect, cornerWidth: plankThickness * 0.13,
                cornerHeight: plankThickness * 0.13, transform: nil)
            context.addPath(plankPath)
            context.setFillColor(tone.cg())
            context.fillPath()

            // A thin top bevel gives the planks a sense of depth.
            context.addPath(plankPath)
            context.setStrokeColor(tone.shaded(1.18).cg(0.55))
            context.setLineWidth(size * 0.0022)
            context.strokePath()
        }
    }
}

// Sheen across the top-left, the way Apple's own icons catch light.
let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    sheen, start: CGPoint(x: plate.minX, y: plate.maxY),
    end: CGPoint(x: plate.midX, y: plate.midY), options: [])

context.restoreGState()

// Inner hairline to crisp the edge.
context.addPath(plateShape)
context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
context.setLineWidth(size * 0.004)
context.strokePath()

guard let image = context.makeImage() else { fatalError("couldn't render icon") }

// MARK: - Write iconset

let iconsetURL = outputDirectory.appendingPathComponent("Macquet.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// (pixel size, filename) pairs iconutil expects.
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (pixels, name) in variants {
    guard
        let scaled = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let output = scaled.makeImage() else { continue }

    let fileURL = iconsetURL.appendingPathComponent(name)
    guard
        let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, "public.png" as CFString, 1, nil)
    else { continue }
    CGImageDestinationAddImage(destination, output, nil)
    CGImageDestinationFinalize(destination)
}

print("wrote \(iconsetURL.path)")
