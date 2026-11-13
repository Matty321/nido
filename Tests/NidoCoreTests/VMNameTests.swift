// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import NidoCore

@Suite struct VMNameTests {
    @Test(arguments: ["debian-13", "a", "Dev_VM.2", String(repeating: "a", count: 63)])
    func acceptsValidNames(_ raw: String) throws {
        let name = try VMName(raw)
        #expect(name.rawValue == raw)
        #expect(name.description == raw)
    }

    @Test(arguments: [
        "", "../x", "a/b", ".hidden", "a..b", String(repeating: "a", count: 64),
        "nido;rm", "ñandu", " a", "-x",
    ])
    func rejectsInvalidNames(_ raw: String) {
        #expect(throws: NidoError.invalidName(raw)) { try VMName(raw) }
    }

    @Test func comparisonIsCaseInsensitive() throws {
        #expect(try VMName("Debian") == VMName("debian"))
        #expect(try VMName("Debian").hashValue == VMName("debian").hashValue)
    }
}
