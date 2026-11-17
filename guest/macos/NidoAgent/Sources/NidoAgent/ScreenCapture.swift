// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import ImageIO
import NidoAgentKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures the guest's main display with ScreenCaptureKit (needs Screen Recording).
struct ScreenCapture: ScreenSource {
    enum CaptureError: Error, CustomStringConvertible {
        case noMainDisplay
        case scaleFailed
        case encodeFailed

        var description: String {
            switch self {
            case .noMainDisplay: "the main display is not shareable"
            case .scaleFailed: "could not scale the screenshot"
            case .encodeFailed: "could not encode the screenshot as PNG"
            }
        }
    }

    func screenSize() -> ScreenSize {
        let size = CGDisplayBounds(CGMainDisplayID()).size
        return ScreenSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    func capture(maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) {
        let points = screenSize()
        // Exactly the size the dispatcher (and the host) map coordinates with; never larger
        // than the display in points, so a Retina display is scaled down, never up.
        let target = CoordinateSpace(display: PixelSize(points.width, points.height), maxLongEdge: maxLongEdge).image

        return try await shoot(target: target, sourceRect: nil)
    }

    func capture(region: CGRect, maxLongEdge: Int) async throws -> (png: Data, image: PixelSize) {
        // Backing scale: the display's pixels per point (2 on Retina).
        var density = 1.0
        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 {
            density = Double(mode.pixelWidth) / Double(mode.width)
        }
        let native = PixelSize(max(1, Int((region.width * density).rounded())),
                               max(1, Int((region.height * density).rounded())))
        return try await shoot(target: native.fitted(in: PixelSize(maxLongEdge, maxLongEdge)), sourceRect: region)
    }

    /// The one capture path: the main display (or `sourceRect` of it, in points) as a PNG of
    /// exactly `target` pixels.
    private func shoot(target: PixelSize, sourceRect: CGRect?) async throws -> (png: Data, image: PixelSize) {
        let mainID = CGMainDisplayID()
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == mainID }) else {
            throw CaptureError.noMainDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = target.width
        config.height = target.height
        config.showsCursor = true
        config.capturesAudio = false

        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if image.width != target.width || image.height != target.height {
            // ScreenCaptureKit may round the output size; the reply must carry exactly `target`.
            Log.capture.info("rescaling \(image.width)x\(image.height) to \(target.width)x\(target.height)")
            image = try Self.scale(image, to: target)
        }
        return (try Self.png(image), target)
    }

    private static func scale(_ image: CGImage, to size: PixelSize) throws -> CGImage {
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.scaleFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { throw CaptureError.scaleFailed }
        return scaled
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodeFailed }
        return data as Data
    }
}
