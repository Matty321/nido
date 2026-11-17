// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation

public struct PixelSize: Codable, Equatable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    public var description: String { "\(width)x\(height)" }

    /// Parses "1440x900".
    public init?(parsing s: String) {
        let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
        self.init(p[0], p[1])
    }

    /// Largest size with the same aspect ratio that fits inside `bounds` (never upscales).
    public func fitted(in bounds: PixelSize) -> PixelSize {
        let s = min(1.0, min(Double(bounds.width) / Double(width), Double(bounds.height) / Double(height)))
        return PixelSize(max(1, Int((Double(width) * s).rounded(.down))), max(1, Int((Double(height) * s).rounded(.down))))
    }
}

/// Coordinate space used by agents: the display scaled so its long edge
/// is at most `maxLongEdge`. Screenshots and actions share this space.
public struct CoordinateSpace: Equatable, Sendable {
    public let display: PixelSize
    public let image: PixelSize

    public init(display: PixelSize, maxLongEdge: Int) {
        self.display = display
        let long = max(display.width, display.height)
        if maxLongEdge > 0, long > maxLongEdge {
            let s = Double(maxLongEdge) / Double(long)
            image = PixelSize(Int((Double(display.width) * s).rounded()), Int((Double(display.height) * s).rounded()))
        } else {
            image = display
        }
    }

    public var scale: Double { Double(display.width) / Double(image.width) }

    /// Converts a point in screenshot space to display coordinates (clamped on screen).
    public func toDisplay(x: Double, y: Double) -> (x: Double, y: Double) {
        let dx = min(max(x * Double(display.width) / Double(image.width), 0), Double(display.width - 1))
        let dy = min(max(y * Double(display.height) / Double(image.height), 0), Double(display.height - 1))
        return (dx, dy)
    }

    /// Converts a region in screenshot space to display points: both corners map like
    /// `toDisplay` (so the region is clamped on screen), but the far corner may reach the
    /// display's edge. Nil when less than one point is left.
    public func toDisplayRect(x: Double, y: Double, width: Double, height: Double) -> CGRect? {
        let w = Double(display.width), h = Double(display.height)
        let x0 = min(max(x * w / Double(image.width), 0), w)
        let y0 = min(max(y * h / Double(image.height), 0), h)
        let x1 = min(max((x + width) * w / Double(image.width), 0), w)
        let y1 = min(max((y + height) * h / Double(image.height), 0), h)
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
