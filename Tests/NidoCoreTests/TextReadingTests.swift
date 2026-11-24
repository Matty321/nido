// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import NidoAgentKit
import Testing
import UniformTypeIdentifiers
@testable import NidoCore

@Suite struct TextReadingTests {
    private let region = PixelRect(x: 100, y: 50, w: 400, h: 200)
    private let screen = PixelSize(1000, 800)

    @Test func mapsBoxesIntoTheRegion() {
        let found = [RecognizedText(text: "a", box: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))]
        let r = TextReading.lines(found, region: region, screenshot: screen, maxLines: 10)
        #expect(r.lines == [TextLine(text: "a", frame: PixelRect(x: 200, y: 100, w: 200, h: 50))])
        #expect(!r.truncated)
    }

    @Test func framesAreClampedToTheScreenshot() {
        let big = PixelRect(x: 900, y: 700, w: 400, h: 400)
        let found = [RecognizedText(text: "a", box: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))]
        let r = TextReading.lines(found, region: big, screenshot: screen, maxLines: 10)
        let f = r.lines[0].frame
        #expect(f.x + f.w <= 1000)
        #expect(f.y + f.h <= 800)
        #expect(f.x >= 0 && f.y >= 0 && f.w >= 0 && f.h >= 0)
    }

    @Test func ordersTopToBottomThenLeftToRight() {
        let found = [
            RecognizedText(text: "right", box: CGRect(x: 0.6, y: 0.5, width: 0.2, height: 0.1)),
            RecognizedText(text: "bottom", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)),
            RecognizedText(text: "left", box: CGRect(x: 0.1, y: 0.51, width: 0.2, height: 0.1)),
            RecognizedText(text: "top", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1)),
        ]
        let r = TextReading.lines(found, region: region, screenshot: screen, maxLines: 10)
        #expect(r.lines.map(\.text) == ["top", "left", "right", "bottom"])
    }

    @Test func capsAndMarksTruncated() {
        let found = (0..<5).map {
            RecognizedText(text: "t\($0)", box: CGRect(x: 0, y: 0.1 * Double($0), width: 0.2, height: 0.05))
        }
        let r = TextReading.lines(found, region: region, screenshot: screen, maxLines: 3)
        #expect(r.lines.count == 3)
        #expect(r.truncated)
    }

    @Test func dropsEmptyTexts() {
        let found = [
            RecognizedText(text: "  \n", box: CGRect(x: 0, y: 0, width: 0.2, height: 0.1)),
            RecognizedText(text: " hi ", box: CGRect(x: 0, y: 0.5, width: 0.2, height: 0.1)),
        ]
        let r = TextReading.lines(found, region: region, screenshot: screen, maxLines: 10)
        #expect(r.lines.map(\.text) == ["hi"])
        #expect(!r.truncated)
    }

    @Test func visionReadsRenderedText() async throws {
        let png = try Self.renderPNG("Nido 42")
        let found = try await VisionTextRecognizer().recognize(png: png)
        let joined = found.map(\.text).joined(separator: " | ")
        #expect(found.contains { $0.text.contains("Nido 42") }, "recognized: \(joined)")
    }

    static func renderPNG(_ text: String) throws -> Data {
        let w = 600, h = 200
        let ctx = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: 30, y: 70)
        CTLineDraw(line, ctx)
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
