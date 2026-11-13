// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

@Suite struct GuestToolsPayloadTests {
    private var guest: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("guest/linux")
    }

    /// The runtime files, regenerated in memory from the sources: (install path, mode, bytes).
    private func expectedFiles() throws -> [(path: String, mode: String, data: Data)] {
        let fm = FileManager.default
        var result: [(String, String, Data)] = []
        let modules = try fm.contentsOfDirectory(atPath: guest.appendingPathComponent("nido_guest_tools").path)
            .filter { $0.hasSuffix(".py") }
        for name in modules {
            result.append((
                "/opt/nido-guest-tools/nido_guest_tools/\(name)", "0644",
                try Data(contentsOf: guest.appendingPathComponent("nido_guest_tools/\(name)"))))
        }
        result.append((
            "/opt/nido-guest-tools/bin/nido-guest-tools", "0755",
            try Data(contentsOf: guest.appendingPathComponent("bin/nido-guest-tools"))))
        result.append((
            "/opt/nido-guest-tools/bin/nido-ai-bridge", "0755",
            try Data(contentsOf: guest.appendingPathComponent("bin/nido-ai-bridge"))))
        result.append((
            "/opt/nido-guest-tools/bin/nido-provision", "0755",
            try Data(contentsOf: guest.appendingPathComponent("bin/nido-provision"))))
        for name in ["ollama.service", "release.json"] {
            result.append((
                "/opt/nido-guest-tools/ollama/\(name)", "0644",
                try Data(contentsOf: guest.appendingPathComponent("ollama/\(name)"))))
        }
        result.append((
            "/opt/nido-guest-tools/VERSION", "0644", try Data(contentsOf: guest.appendingPathComponent("VERSION"))))
        result.append((
            "/etc/systemd/system/nido-guest-tools.service", "0644",
            try Data(contentsOf: guest.appendingPathComponent("systemd/nido-guest-tools.service"))))
        result.append((
            "/etc/systemd/system/nido-ai-bridge.service", "0644",
            try Data(contentsOf: guest.appendingPathComponent("systemd/nido-ai-bridge.service"))))
        return result.sorted { $0.0 < $1.0 }
    }

    @Test func payloadMatchesSources() throws {
        let expected = try expectedFiles()
        #expect(GuestToolsPayload.files.map(\.path) == expected.map(\.path))
        for (file, source) in zip(GuestToolsPayload.files, expected) {
            #expect(file.mode == source.mode, "\(file.path)")
            #expect(file.base64 == source.data.base64EncodedString(), "\(file.path) differs from the sources")
        }
        let version = try String(contentsOf: guest.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(GuestToolsPayload.version == version.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(GuestToolsPayload.version == "1.5.0")
    }

    @Test func payloadHasRuntimeFilesOnly() {
        for file in GuestToolsPayload.files {
            #expect(!file.path.contains("tests"))
            #expect(!file.path.contains("reference"))
            #expect(!file.path.contains("README"))
            #expect(!file.path.contains("__pycache__"))
        }
        #expect(GuestToolsPayload.files.first { $0.path.hasSuffix("/bin/nido-guest-tools") }?.mode == "0755")
        #expect(GuestToolsPayload.files.first { $0.path.hasSuffix("/bin/nido-provision") }?.mode == "0755")
    }

    /// Ollama is phase 2 only: its unit ships in a staging path that neither cloud-init nor the
    /// Guest Tools installer enables; `nido-provision ollama-install` copies it into place.
    @Test func ollamaUnitIsNotASystemdUnitOfThePayload() throws {
        let units = GuestToolsPayload.files.filter { $0.path.hasPrefix("/etc/systemd/system/") }
        #expect(units.map(\.path) == [
            "/etc/systemd/system/nido-ai-bridge.service", "/etc/systemd/system/nido-guest-tools.service",
        ])
        #expect(GuestToolsPayload.files.contains { $0.path == "/opt/nido-guest-tools/ollama/ollama.service" })
        let script = try GuestToolsInstaller.installScript(
            files: GuestToolsPayload.files.map { ($0.path, $0.mode, $0.base64) })
        #expect(!script.contains("enable 'ollama.service'"))
        #expect(!script.contains("enable --now 'ollama.service'"))
        let userData = CloudInitSeed.userData(
            username: "nido", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq1fl8b3Zr2iKcK1nBcDeFg8hIj0kLmNoPqRsTuVwXy",
            profile: .standard)
        #expect(!userData.contains("ollama.service]"))
        #expect(!userData.contains("enable, --now, ollama"))
    }

    /// The AI bridge shim ships as a unit of the payload: cloud-init and the installer (which
    /// enables every unit under /etc/systemd/system/) both start it.
    @Test func payloadIncludesBridge() throws {
        let paths = GuestToolsPayload.files.map(\.path)
        #expect(paths.contains("/opt/nido-guest-tools/nido_guest_tools/bridge.py"))
        #expect(GuestToolsPayload.files.first { $0.path == "/opt/nido-guest-tools/bin/nido-ai-bridge" }?.mode == "0755")
        let unit = try #require(GuestToolsPayload.files.first { $0.path == "/etc/systemd/system/nido-ai-bridge.service" })
        let text = String(decoding: try #require(Data(base64Encoded: unit.base64)), as: UTF8.self)
        #expect(text.contains("IPAddressDeny=any\n"))
        #expect(text.contains("IPAddressAllow=localhost\n"))
        #expect(text.contains("DynamicUser=yes\n"))
        let script = try GuestToolsInstaller.installScript(
            files: GuestToolsPayload.files.map { ($0.path, $0.mode, $0.base64) })
        #expect(script.contains("systemctl enable --now 'nido-ai-bridge.service'"))
        #expect(script.contains("systemctl enable 'nido-ai-bridge.service'; systemctl restart 'nido-ai-bridge.service'"))
    }

    @Test func releaseIsPinnedWithOfficialChecksum() throws {
        let file = try #require(GuestToolsPayload.files.first { $0.path.hasSuffix("/ollama/release.json") })
        let data = try #require(Data(base64Encoded: file.base64))
        let release = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(release["version"] as? String == "0.40.10")
        #expect(release["url"] as? String
            == "https://github.com/ollama/ollama/releases/download/v0.40.10/ollama-linux-arm64.tar.zst")
        #expect(release["sha256"] as? String == "57dca26f51efc050112b733a65dea6f6c8e68da7a2946afd7c1eb8834d9eeb92")
        #expect(release["size"] as? Int == 1_564_567_595)
        #expect(release["checked"] as? String == "2026-10-24")
    }
}
