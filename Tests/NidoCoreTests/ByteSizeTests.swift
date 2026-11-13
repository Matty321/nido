// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct ByteSizeTests {
    @Test(arguments: [
        ("4G", UInt64(4_294_967_296)), ("512M", 536_870_912), ("0", 0), ("1024", 1024),
        ("2K", 2048), ("1T", 1_099_511_627_776), ("4g", 4_294_967_296),
    ])
    func parsesValidSizes(_ input: String, _ expected: UInt64) throws {
        #expect(try ByteSize.parse(input) == expected)
    }

    @Test(arguments: ["-1G", "4X", "99999999999T", "", "G", "1.5G", " 4G", "4GB", "+4G", "18446744073709551616"])
    func rejectsInvalidSizes(_ input: String) {
        #expect(throws: NidoError.invalidSize(input)) { try ByteSize.parse(input) }
    }
}

/// The decimal separator follows the language; whole sizes and units are the same everywhere.
struct ByteSizeFormatTests {
    @Test func decimalSeparatorFollowsTheLocale() {
        #expect(ByteSize.format(3 << 29, locale: Locale(identifier: "en")) == "1.5 GiB")
        #expect(ByteSize.format(3 << 29, locale: Locale(identifier: "it")) == "1,5 GiB")
        #expect(ByteSize.format(3 << 29, locale: Locale(identifier: "de")) == "1,5 GiB")
        #expect(ByteSize.format(3 << 29, locale: Locale(identifier: "fr")) == "1,5 GiB")
        #expect(ByteSize.format(4 << 30, locale: Locale(identifier: "fr")) == "4 GiB")
        #expect(ByteSize.format(1023, locale: Locale(identifier: "es")) == "1023 B")
    }
}
