// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Testing
@testable import NidoAgentKit

@Test func coordinateSpaceScales() {
    let cs = CoordinateSpace(display: PixelSize(1440, 900), maxLongEdge: 1280)
    #expect(cs.image == PixelSize(1280, 800))
    let p = cs.toDisplay(x: 640, y: 400)
    #expect(abs(p.x - 720) < 0.001)
    #expect(abs(p.y - 450) < 0.001)
    let c = cs.toDisplay(x: 5000, y: -3)
    #expect(abs(c.x - 1439) < 0.001)
    #expect(abs(c.y - 0) < 0.001)
    #expect(CoordinateSpace(display: PixelSize(1024, 768), maxLongEdge: 1280).image == PixelSize(1024, 768))
}

@Test func regionMapsLikePoints() {
    let cs = CoordinateSpace(display: PixelSize(1024, 640), maxLongEdge: 512)
    #expect(cs.image == PixelSize(512, 320))
    #expect(cs.toDisplayRect(x: 10, y: 20, width: 100, height: 50) == CGRect(x: 20, y: 40, width: 200, height: 100))
    let clamped = cs.toDisplayRect(x: 500, y: 20, width: 100, height: 50)
    #expect(clamped?.maxX == 1024)
    #expect(cs.toDisplayRect(x: 600, y: 20, width: 100, height: 50) == nil)
}

@Test func toImageInvertsToDisplay() {
    let cs = CoordinateSpace(display: PixelSize(1024, 640), maxLongEdge: 512)
    #expect(cs.image == PixelSize(512, 320))
    let p = cs.toImage(x: 200, y: 100)
    #expect(abs(p.x - 100) < 0.001)
    #expect(abs(p.y - 50) < 0.001)
    // Unclamped: a point off the display maps off the image.
    let off = cs.toImage(x: -20, y: 2000)
    #expect(abs(off.x + 10) < 0.001)
    #expect(abs(off.y - 1000) < 0.001)
}

@Test func toImageRectClampsAndDrops() {
    let cs = CoordinateSpace(display: PixelSize(1024, 640), maxLongEdge: 512)
    #expect(cs.toImageRect(CGRect(x: 100, y: 200, width: 80, height: 24)) == PixelRect(x: 50, y: 100, w: 40, h: 12))
    #expect(cs.toImageRect(CGRect(x: 1000, y: 600, width: 100, height: 100)) == PixelRect(x: 500, y: 300, w: 12, h: 20))
    #expect(cs.toImageRect(CGRect(x: -20, y: 10, width: 60, height: 20)) == PixelRect(x: 0, y: 5, w: 20, h: 10))
    #expect(cs.toImageRect(CGRect(x: 10, y: 10, width: 0, height: 20)) == nil)
    #expect(cs.toImageRect(CGRect(x: 2000, y: 10, width: 50, height: 20)) == nil)
    #expect(cs.toImageRect(CGRect(x: -200, y: 10, width: 50, height: 20)) == nil)
    #expect(cs.toImageRect(CGRect(x: Double.nan, y: 10, width: 50, height: 20)) == nil)
    #expect(cs.toImageRect(CGRect(x: 10, y: 10, width: Double.infinity, height: 20)) == nil)
}
