// SPDX-License-Identifier: Apache-2.0
//
// Pixel comparison of a design render and an app screenshot (CoreGraphics and ImageIO only).
//
//   swift scripts/visual-diff.swift <design.png> <app.png> [--tolerance 16] [--max-diff 3%]
//                                   [--crop x,y,w,h | --crop-at x,y] [--diff out.png]
//
// Both images are drawn into 8-bit RGBA sRGB bitmaps (so a Display P3 screenshot and an sRGB render
// are compared in the same colour space). A pixel differs when any channel differs by more than
// `--tolerance`/255. The result is the share of differing pixels; above `--max-diff` the exit code
// is 1. `--crop` cuts the design image first (pixels, top-left origin): the FigCraft renders carry
// the window's drop shadow around it, the screenshot does not. After the crop both images must have
// the same size (exit 2 otherwise). `--crop-at x,y` cuts the design image at x,y to the size of
// the app image (a part of the window, e.g. the wizard's dialog captured on its own). `--diff`
// writes a PNG: the app image dimmed to grey, differing pixels in red.
//
// Exit codes: 0 within the threshold, 1 above it, 2 usage or I/O error, or sizes that differ.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var design = ""
    var app = ""
    var tolerance = 16
    var maxDiff = 3.0
    var crop: CGRect?
    var cropAt: CGPoint?
    var diffOut: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("visual-diff: \(message)\n".utf8))
    exit(2)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var positional: [String] = []
    var index = 0
    func value(_ flag: String) -> String {
        index += 1
        guard index < arguments.count else { fail("missing value for \(flag)") }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--tolerance":
            guard let number = Int(value(argument)), (0...255).contains(number) else { fail("--tolerance: 0…255") }
            options.tolerance = number
        case "--max-diff":
            let raw = value(argument)
            let text = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
            guard let number = Double(text), (0...100).contains(number) else { fail("--max-diff: 0…100%") }
            options.maxDiff = number
        case "--crop":
            let parts = value(argument).split(separator: ",").compactMap { Int($0) }
            guard parts.count == 4, parts[2] > 0, parts[3] > 0, parts[0] >= 0, parts[1] >= 0 else {
                fail("--crop: x,y,w,h in pixels")
            }
            options.crop = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        case "--crop-at":
            let parts = value(argument).split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2, parts[0] >= 0, parts[1] >= 0 else { fail("--crop-at: x,y in pixels") }
            options.cropAt = CGPoint(x: parts[0], y: parts[1])
        case "--diff":
            options.diffOut = value(argument)
        default:
            if argument.hasPrefix("--") { fail("unknown option \(argument)") }
            positional.append(argument)
        }
        index += 1
    }
    if options.crop != nil, options.cropAt != nil { fail("--crop and --crop-at are mutually exclusive") }
    guard positional.count == 2 else {
        fail("usage: visual-diff.swift <design.png> <app.png> [--tolerance 16] [--max-diff 3%] "
            + "[--crop x,y,w,h | --crop-at x,y] [--diff out.png]")
    }
    options.design = positional[0]
    options.app = positional[1]
    return options
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("can’t read \(path)") }
    return image
}

/// The image as tightly packed RGBA8 in sRGB, premultiplied over nothing (alpha kept).
func rgba(_ image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    if !drawn { fail("graphics context unavailable") }
    return pixels
}

func writePNG(_ pixels: [UInt8], width: Int, height: Int, to path: String) {
    var copy = pixels
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let image = copy.withUnsafeMutableBytes { buffer -> CGImage? in
        CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    let url = URL(fileURLWithPath: path)
    guard let image,
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("can’t write \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) { fail("can’t write \(path)") }
}

var options = parse(Array(CommandLine.arguments.dropFirst()))
var design = load(options.design)
let app = load(options.app)
if let origin = options.cropAt {
    options.crop = CGRect(origin: origin, size: CGSize(width: app.width, height: app.height))
}
if let crop = options.crop {
    guard crop.maxX <= CGFloat(design.width), crop.maxY <= CGFloat(design.height),
          let cropped = design.cropping(to: crop)
    else { fail("--crop outside \(options.design) (\(design.width)×\(design.height))") }
    design = cropped
}
guard design.width == app.width, design.height == app.height else {
    fail("sizes differ: \(options.design) \(design.width)×\(design.height), "
        + "\(options.app) \(app.width)×\(app.height)")
}

let width = app.width, height = app.height
let a = rgba(design), b = rgba(app)
var differing = 0
var diff = [UInt8](repeating: 0, count: width * height * 4)
for pixel in 0..<(width * height) {
    let offset = pixel * 4
    var isDifferent = false
    for channel in 0..<4 where abs(Int(a[offset + channel]) - Int(b[offset + channel])) > options.tolerance {
        isDifferent = true
        break
    }
    if isDifferent {
        differing += 1
        diff[offset] = 230; diff[offset + 1] = 30; diff[offset + 2] = 30
    } else {
        // The app image as light grey, so the red marks stand out.
        let grey = UInt8((Int(b[offset]) + Int(b[offset + 1]) + Int(b[offset + 2])) / 3 / 3 + 170)
        diff[offset] = grey; diff[offset + 1] = grey; diff[offset + 2] = grey
    }
    diff[offset + 3] = 255
}
if let out = options.diffOut { writePNG(diff, width: width, height: height, to: out) }

let percent = Double(differing) / Double(width * height) * 100
let verdict = percent <= options.maxDiff ? "ok" : "above the threshold"
print(String(format: "%.2f%% pixels differ (%d of %d, tolerance %d/255, threshold %.1f%%): %@",
             percent, differing, width * height, options.tolerance, options.maxDiff, verdict))
exit(percent <= options.maxDiff ? 0 : 1)
