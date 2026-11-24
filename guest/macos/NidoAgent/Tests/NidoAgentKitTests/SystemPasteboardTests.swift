// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import Testing
@testable import NidoAgentKit

/// `SystemPasteboard` on a named pasteboard: the user's clipboard is never touched and no
/// paste-privacy prompt appears. The pasteboard is released at the end of each test.
@MainActor
@Suite struct SystemPasteboardTests {
    private let concealed = SystemPasteboard.concealedType
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private func make(denied: Bool = false) -> (NSPasteboard, SystemPasteboard) {
        let named = NSPasteboard.withUniqueName()
        return (named, SystemPasteboard(pasteboard: named, isReadDenied: { denied }))
    }

    @Test func writeConcealedDeclaresStringAndMarkerThenReadRefuses() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        let count = sut.writeConcealed("pw-123")
        #expect(named.types?.contains(.string) == true)
        #expect(named.types?.contains(concealed) == true)
        #expect(named.string(forType: .string) == "pw-123")
        #expect(count == named.changeCount)
        #expect(sut.readPlain() == .concealed)
    }

    @Test func plainWriteThenReadReturnsTheText() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        let count = sut.writePlain("hello")
        #expect(count == named.changeCount)
        #expect(named.types?.contains(concealed) != true)
        #expect(sut.readPlain() == .text("hello"))
    }

    @Test func emptyPasteboardHasNoText() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        named.clearContents()
        #expect(sut.readPlain() == .none)
    }

    @Test func emptyStringIsNoText() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        named.clearContents()
        named.setString("", forType: .string)
        #expect(sut.readPlain() == .none)
    }

    @Test func clearContentsEmptiesIt() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        _ = sut.writePlain("x")
        sut.clearContents()
        #expect(sut.readPlain() == .none)
    }

    /// An app writes clearContents, setString(password) and only then adds the marker: the change
    /// count does not move on those last two, so only the check after the read catches it.
    @Test func markerAddedWhileReadingIsStillRefused() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        named.clearContents()
        named.setString("pw", forType: .string)
        let concealed = self.concealed
        sut.afterReadingString = {
            named.addTypes([concealed], owner: nil)
            named.setData(Data(), forType: concealed)
        }
        #expect(sut.readPlain() == .concealed)
    }

    @Test func writePlainReturnsTheChangeCount() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        #expect(sut.writePlain("a") == named.changeCount)
    }

    @Test func transientItemIsNotReadable() {
        let (named, sut) = make()
        defer { named.releaseGlobally() }
        named.declareTypes([.string, transient], owner: nil)
        named.setString("one-time", forType: .string)
        named.setData(Data(), forType: transient)
        #expect(sut.readPlain() == .concealed)
    }

    @Test func deniedPasteAccessIsReported() {
        let (named, sut) = make(denied: true)
        defer { named.releaseGlobally() }
        _ = sut.writePlain("x")
        #expect(sut.readPlain() == .denied)
    }
}
