// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// Sizes as the app shows them, in one place: binary units, the decimal separator of the app's
/// locale (`Locale.current`): "1.2 GiB" in English, "1,2 GiB" in Italian.
extension ByteSize {
    nonisolated static func text(_ bytes: UInt64) -> String {
        format(bytes, locale: .current)
    }

    /// A size reported as a signed number (the guest's, a sum): below zero shows as 0 B.
    nonisolated static func text(_ bytes: Int64) -> String {
        text(UInt64(max(0, bytes)))
    }
}
