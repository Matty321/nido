// SPDX-License-Identifier: Apache-2.0
// Compiled into NidoCoreTests and NidoCLITests (Tests/NidoCLITests/ItalianCopy.swift is a symlink
// to this file): one source for both test processes.
import Testing
@_spi(Testing) import NidoCore

/// The trait of every suite that asserts NidoCore's Italian copy (`@Suite(.italian)`): the whole
/// test process is pinned to Italian once, by whichever such suite runs first, and never moved
/// again. Swift Testing runs suites in parallel and `L10n.pin` is process-wide, so no suite pins
/// another language: English, German, Spanish and French are checked through
/// `L10n.string(_:language:)` and the `language:` variants of the descriptions.
struct ItalianCopy: SuiteTrait, TestTrait {
    var isRecursive: Bool { true }

    func prepare(for test: Test) async throws {
        _ = Self.pinned
    }

    /// Runs once per process (a lazy global), before the first Italian-asserting test.
    private static let pinned: Void = L10n.pin("it")
}

extension Trait where Self == ItalianCopy {
    /// NidoCore's text in Italian for this suite and the rest of the process.
    static var italian: Self { ItalianCopy() }
}
