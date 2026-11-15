// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite(.italian) struct MacAgentBundleTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macagent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: root) }

    private func makeApp(_ url: URL, version: String = "1.0.0") throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": version]
        try (plist as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    @Test func candidatesFollowLinks() throws {
        defer { cleanup() }
        let helper = root.appendingPathComponent("App.app/Contents/Helpers/nido")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: helper)
        let bin = root.appendingPathComponent("home/.local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("nido")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        let home = root.appendingPathComponent("home")

        let candidates = MacAgentBundle.candidates(executable: link, home: home)
        #expect(candidates.count == 3)
        let contents = helper.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        #expect(candidates[0].standardized.path
            == contents.appendingPathComponent("Resources/NidoAgent.app").standardized.path)
        #expect(candidates[1].standardized.path.hasSuffix("App.app/Contents/Helpers/NidoAgent.app"))
        #expect(candidates[2].standardized.path
            == home.appendingPathComponent(".local/libexec/nido/NidoAgent.app").standardized.path)
    }

    @Test func skipsSymlinkedApp() throws {
        defer { cleanup() }
        let executable = root.appendingPathComponent("App.app/Contents/Helpers/nido")
        let home = root.appendingPathComponent("home")
        let candidates = MacAgentBundle.candidates(executable: executable, home: home)
        let target = root.appendingPathComponent("elsewhere.app")
        try makeApp(target)
        try FileManager.default.createDirectory(
            at: candidates[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: candidates[0], withDestinationURL: target)
        try makeApp(candidates[1])
        #expect(try MacAgentBundle.locate(executable: executable, home: home, verify: { _ in true })
            .resolvingSymlinksInPath() == candidates[1].resolvingSymlinksInPath())
    }

    @Test func noneFoundThrows() throws {
        defer { cleanup() }
        let executable = root.appendingPathComponent("App.app/Contents/Helpers/nido")
        let home = root.appendingPathComponent("home")
        try makeApp(MacAgentBundle.candidates(executable: executable, home: home)[0])
        #expect(throws: NidoError.macAgentUnavailable) {
            try MacAgentBundle.locate(executable: executable, home: home, verify: { _ in false })
        }
        #expect(NidoError.macAgentUnavailable.errorDescription == "Nido Agent non è in questa build di Nido")
    }

    @Test func readsBundledVersion() throws {
        defer { cleanup() }
        let app = root.appendingPathComponent("NidoAgent.app")
        try makeApp(app, version: "1.0.0")
        #expect(try MacAgentBundle.bundledVersion(app) == "1.0.0")
    }

    @Test func requirementPinsTeam() {
        #expect(MacAgentBundle.requirement(teamID: nil) == "identifier \"io.gitlab.pichierri.Nido.Agent\"")
        #expect(MacAgentBundle.requirement(teamID: "ABCDE12345")
            == "anchor apple generic and identifier \"io.gitlab.pichierri.Nido.Agent\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }
}
