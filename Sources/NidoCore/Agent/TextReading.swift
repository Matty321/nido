// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreText
import ImageIO
import Foundation
import NidoAgentKit
import Vision

/// One line of text found on the guest's screen, with its frame in the pixels of the latest screenshot.
public struct TextLine: Codable, Equatable, Sendable {
    public let text: String
    public let frame: PixelRect

    public init(text: String, frame: PixelRect) {
        self.text = text
        self.frame = frame
    }
}

/// Text found by the recognizer. `box` is Vision-normalized: 0...1 over the recognized image,
/// origin at the bottom left.
public struct RecognizedText: Sendable {
    public let text: String
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

public protocol TextRecognizing: Sendable {
    func recognize(png: Data) async throws -> [RecognizedText]
}

/// Recognizes text with Vision on the host. The capture never leaves the Mac.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(png: Data) async throws -> [RecognizedText] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: png)
        return observations.compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            return RecognizedText(text: top.string, box: observation.boundingBox.cgRect)
        }
    }
}

/// Wraps a recognizer and warms it up in the background as soon as it is made: Vision loads and
/// compiles its text model on the first recognition of a process, which can take tens of seconds.
/// A recognition waits for that one load, never starting another.
public final class WarmedTextRecognizer: TextRecognizing {
    private let base: any TextRecognizing
    private let warm: Task<Void, Never>

    public init(_ base: any TextRecognizing) {
        self.base = base
        warm = Task.detached(priority: .utility) {
            guard let png = Self.sample() else { return }
            _ = try? await base.recognize(png: png)
        }
    }

    public func recognize(png: Data) async throws -> [RecognizedText] {
        await warm.value
        return try await base.recognize(png: png)
    }

    /// A small PNG with a word on it: enough for the text model to load.
    static func sample() -> Data? {
        let width = 240, height = 80
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Nido text", attributes: attributes))
        context.textPosition = CGPoint(x: 12, y: 24)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

public enum TextReading {
    /// Maps recognized text to screenshot pixels: frame = region origin + normalized box (flipped to
    /// a top-left origin) x region size, rounded, clamped to the screenshot. Empty texts are dropped;
    /// lines are ordered top to bottom, then left to right (vertical centres closer than half the
    /// smaller height count as one row); at most `maxLines` are kept.
    public static func lines(
        _ found: [RecognizedText], region: PixelRect, screenshot: PixelSize, maxLines: Int
    ) -> (lines: [TextLine], truncated: Bool) {
        struct Item {
            let line: TextLine
            let centreY: Double
        }
        let items: [Item] = found.compactMap { f in
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let rw = Double(region.w), rh = Double(region.h)
            let x0 = (Double(region.x) + f.box.minX * rw).rounded()
            let x1 = (Double(region.x) + f.box.maxX * rw).rounded()
            let y0 = (Double(region.y) + (1 - f.box.maxY) * rh).rounded()
            let y1 = (Double(region.y) + (1 - f.box.minY) * rh).rounded()
            let cx0 = min(max(Int(x0), 0), screenshot.width)
            let cx1 = min(max(Int(x1), cx0), screenshot.width)
            let cy0 = min(max(Int(y0), 0), screenshot.height)
            let cy1 = min(max(Int(y1), cy0), screenshot.height)
            let frame = PixelRect(x: cx0, y: cy0, w: cx1 - cx0, h: cy1 - cy0)
            return Item(line: TextLine(text: text, frame: frame), centreY: Double(cy0 + cy1) / 2)
        }
        // Group into rows going down the screen, then order each row left to right.
        var rows: [[Item]] = []
        for item in items.sorted(by: { $0.centreY < $1.centreY }) {
            if let last = rows.last?.last,
               abs(item.centreY - last.centreY)
                < Double(min(item.line.frame.h, last.line.frame.h)) / 2 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        let ordered = rows.flatMap { $0.sorted { $0.line.frame.x < $1.line.frame.x } }.map(\.line)
        let limit = max(maxLines, 0)
        return (Array(ordered.prefix(limit)), ordered.count > limit)
    }
}
