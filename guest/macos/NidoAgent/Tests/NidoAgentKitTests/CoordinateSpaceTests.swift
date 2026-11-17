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
