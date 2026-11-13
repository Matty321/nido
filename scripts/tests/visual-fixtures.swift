// SPDX-License-Identifier: Apache-2.0
//
// Writes the PNGs for the visual-diff self-tests into <dir>:
//   base.png     200×100, a deterministic pattern;
//   altered.png  base.png with a 40×50 rectangle (10 % of the pixels) changed by 64/255;
//   faint.png    base.png with every pixel changed by 8/255 (within the tolerance);
//   framed.png   base.png inside a 20 px border on a 240×140 canvas (for --crop 20,20,200,100);
//   small.png    100×100 (sizes that differ).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func write(_ name: String, width: Int, height: Int, in dir: URL, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) {
    var data = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let offset = (y * width + x) * 4
            data[offset] = r; data[offset + 1] = g; data[offset + 2] = b
        }
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let image = data.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    let url = dir.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "cannot write \(url.path)")
}

func base(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    (UInt8(40 + x % 160), UInt8(60 + y), UInt8(100 + (x + y) % 100))
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
write("base.png", width: 200, height: 100, in: dir, pixel: base)
write("altered.png", width: 200, height: 100, in: dir) { x, y in
    let (r, g, b) = base(x, y)
    return (60..<100).contains(x) && (20..<70).contains(y) ? (r &+ 64, g, b) : (r, g, b)
}
write("faint.png", width: 200, height: 100, in: dir) { x, y in
    let (r, g, b) = base(x, y)
    return (r + 8, g + 8, b + 8)
}
write("framed.png", width: 240, height: 140, in: dir) { x, y in
    (20..<220).contains(x) && (20..<120).contains(y) ? base(x - 20, y - 20) : (0, 0, 0)
}
write("small.png", width: 100, height: 100, in: dir, pixel: base)
