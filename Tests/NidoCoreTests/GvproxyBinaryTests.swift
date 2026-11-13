// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite(.italian) struct GvproxyBinaryTests {
    /// A temporary layout: `<root>/App/Contents/MacOS/Nido`, `<root>/home`.
    private struct Layout {
        let root: URL
        let executable: URL
        let home: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("gvproxy-\(UUID().uuidString)", isDirectory: true)
            executable = root.appendingPathComponent("App/Contents/MacOS/Nido")
            home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func place(_ url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func prefersTheAppHelperThenDebugThenInstalled() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let candidates = GvproxyBinary.candidates(executable: layout.executable, home: layout.home)
        #expect(candidates.count == 3)
        #expect(candidates[0].standardized.path.hasSuffix("App/Contents/Helpers/gvproxy"))
        #expect(candidates[1].standardized.path.hasSuffix("App/Contents/MacOS/libexec/gvproxy"))
        #expect(candidates[2].standardized.path == layout.home.appendingPathComponent(".local/libexec/nido/gvproxy").standardized.path)

        for url in candidates { try layout.place(url) }
        #expect(try GvproxyBinary.locate(executable: layout.executable, home: layout.home, verify: { _ in true })
            .standardized == candidates[0].standardized)
        try FileManager.default.removeItem(at: candidates[0])
        #expect(try GvproxyBinary.locate(executable: layout.executable, home: layout.home, verify: { _ in true })
            .standardized == candidates[1].standardized)
        try FileManager.default.removeItem(at: candidates[1])
        #expect(try GvproxyBinary.locate(executable: layout.executable, home: layout.home, verify: { _ in true })
            .standardized == candidates[2].standardized)
    }

    @Test func ignoresSymlinksAndPath() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let candidates = GvproxyBinary.candidates(executable: layout.executable, home: layout.home)
        // A symlink in the first slot is skipped; the real file in the last slot wins.
        let target = layout.root.appendingPathComponent("elsewhere")
        try layout.place(target)
        try FileManager.default.createDirectory(
            at: candidates[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: candidates[0], withDestinationURL: target)
        try layout.place(candidates[2])
        #expect(try GvproxyBinary.locate(executable: layout.executable, home: layout.home, verify: { _ in true })
            .standardized == candidates[2].standardized)

        // A gvproxy on PATH is never used.
        let pathDir = layout.root.appendingPathComponent("bin")
        try layout.place(pathDir.appendingPathComponent("gvproxy"))
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", pathDir.path, 1)
        defer { if let oldPath { setenv("PATH", oldPath, 1) } }
        try FileManager.default.removeItem(at: candidates[2])
        #expect(throws: NidoError.controlledNetworkUnavailable("gvproxy non trovato")) {
            try GvproxyBinary.locate(executable: layout.executable, home: layout.home, verify: { _ in true })
        }
    }

    @Test func rejectsAnUnexpectedBinary() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        try layout.place(GvproxyBinary.candidates(executable: layout.executable, home: layout.home)[2])
        #expect(throws: NidoError.controlledNetworkUnavailable("gvproxy non è quello atteso")) {
            try GvproxyBinary.locate(executable: layout.executable, home: layout.home, verify: { _ in false })
        }
    }

    @Test func missingBinaryFailsClosed() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        #expect(throws: NidoError.controlledNetworkUnavailable("gvproxy non trovato")) {
            try GvproxyBinary.locate(executable: layout.executable, home: layout.home, verify: { _ in true })
        }
    }

    @Test func plainFileWithoutSignatureIsNotValid() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let file = layout.root.appendingPathComponent("gvproxy")
        try layout.place(file)
        #expect(!GvproxyBinary.hasValidSignature(file))
    }

    @Test func resolvesSymlinkedExecutable() throws {
        let layout = try Layout()
        defer { layout.cleanup() }
        let helper = layout.root.appendingPathComponent("App/Contents/Helpers/nido")
        try layout.place(helper)
        // home/.local/bin/nido -> relative link -> second link -> the real helper.
        let bin = layout.home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hop = layout.root.appendingPathComponent("hop")
        try FileManager.default.createSymbolicLink(at: hop, withDestinationURL: helper)
        let link = bin.appendingPathComponent("nido")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../hop")
        let first = GvproxyBinary.candidates(executable: link, home: layout.home)[0]
        #expect(first.standardized.path.hasSuffix("App/Contents/Helpers/gvproxy"))
    }

    @Test func requirementPinsTeamWhenSigned() {
        #expect(GvproxyBinary.requirement(teamID: "ABCDE12345")
            == "anchor apple generic and identifier \"io.gitlab.pichierri.Nido.gvproxy\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    @Test func requirementIsIdentifierOnlyWhenAdHoc() {
        #expect(GvproxyBinary.requirement(teamID: nil) == "identifier \"io.gitlab.pichierri.Nido.gvproxy\"")
    }
}
