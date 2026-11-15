// SPDX-License-Identifier: Apache-2.0
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
