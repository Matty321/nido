// SPDX-License-Identifier: Apache-2.0
import Darwin
import XCTest

/// The fake VMs, logs and snapshots the screenshot tests build in a scratch root (`-NidoRoot`), and
/// the lookups they share. Used by ScreenshotTests (Italian, compared with the renders) and
/// LanguageScreensTests (every other language).
protocol ScreenFixtures: AnyObject {
    /// The scratch root the app is launched on (`-NidoRoot`).
    var root: URL! { get }
    /// The bundle locks held by `holdLock`, released by `releaseLocks`.
    var lockFDs: [Int32] { get set }
}

/// A scratch folder for one test: `VMs` (the root) and a `home` with a valid
/// `~/.ssh/id_ed25519.pub`, which the wizard preselects.
func makeScreenScratch() throws -> (scratch: URL, root: URL, home: URL) {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("nido-screens-\(UUID().uuidString)", isDirectory: true)
    let root = scratch.appendingPathComponent("VMs", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
    try FileManager.default.createDirectory(
        at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO97YvP4YWGQwUFq+UeOnyDKkD29RZ8VdmeuGgPzeS6 test\n".utf8)
        .write(to: ssh.appendingPathComponent("id_ed25519.pub"))
    return (scratch, root, home)
}

extension ScreenFixtures {
    /// The Guest Tools version Nido ships (`guest/linux/VERSION`, `GuestToolsPayload.version`; the
    /// UI test target does not link NidoCore). The renders show 1.0.0.
    static var guestToolsVersion: String { "1.3.0" }

    /// The config of a template made with the shipped Guest Tools (`isTemplate`, schema 3).
    static var templateConfig: [String: Any] {
        ["schemaVersion": 3, "isTemplate": true, "guestToolsVersion": guestToolsVersion,
         "provisioning": ["essentialPackages": true, "guestTools": true]]
    }

    /// The design's AI VM: 4 CPU, 4 GiB, 64 GiB, the shipped Guest Tools, bridge on.
    func makeAIBundle(_ name: String = "debian-ai", bridge: Bool = true, guestTools: Bool = true,
                      pending: [String: Any]? = nil, logs: Bool = false) throws {
        var extra: [String: Any] = ["schemaVersion": 3,
                                    "provisioning": ["essentialPackages": true, "guestTools": true]]
        if guestTools { extra["guestToolsVersion"] = Self.guestToolsVersion }
        if bridge {
            extra["aiBridge"] = ["enabled": true, "privacyAcknowledged": true,
                                 "allowedModels": ["meta-llama/Llama-3.3-70B-Instruct", "openai/gpt-oss-120b"]]
        }
        if let pending { extra["pendingProvisioning"] = pending }
        try makeBundle(name, cpu: 4, memoryGiB: 4, diskGiB: 64, extra: extra)
        guard logs else { return }
        // Today's usage and the last calls of the render (S15 Uso e registro).
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let usage = try JSONSerialization.data(withJSONObject: ["day": day.string(from: Date()), "tokens": 12_480])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: bundleURL(name).appendingPathComponent("ai-bridge-usage.json").path, contents: usage,
            attributes: [.posixPermissions: 0o600]))
        let iso = ISO8601DateFormatter()
        let now = Date()
        let calls: [(Double, String, String?, Int, Int, Int, Int)] = [
            (-420, "openai/gpt-oss-120b", "cerebras", 2104, 958, 200, 6100),
            (-257, "meta-llama/Llama-3.3-70B-Instruct", nil, 0, 0, 429, 0),
            (-255, "meta-llama/Llama-3.3-70B-Instruct", "groq", 640, 211, 200, 2400),
            (-240, "meta-llama/Llama-3.3-70B-Instruct", "groq", 812, 164, 200, 1900),
        ]
        var lines = ""
        for call in calls {
            var entry: [String: Any] = ["time": iso.string(from: now.addingTimeInterval(call.0)), "model": call.1,
                                        "inputTokens": call.3, "outputTokens": call.4, "estimated": false,
                                        "status": call.5, "durationMs": call.6]
            if let provider = call.2 { entry["provider"] = provider }
            lines += String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                            as: UTF8.self) + "\n"
        }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: bundleURL(name).appendingPathComponent("ai-bridge.log").path, contents: Data(lines.utf8),
            attributes: [.posixPermissions: 0o600]))
    }

    @MainActor
    func waitText(_ text: String, in element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        element.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// A segment of a segmented picker (a radio button, or a button on some systems).
    @MainActor
    func segment(_ title: String, in element: XCUIElement) -> XCUIElement {
        let radio = element.radioButtons[title]
        return radio.exists ? radio : element.buttons[title]
    }

    /// debian-13 on the controlled network: its list (`egress.json`) and a log with blocks of
    /// every kind the person sees, plus allowed flows.
    func makeNetworkBundle(controlled: Bool = true, policy: [String]? = nil) throws {
        try makeBundle("debian-13", cpu: 4, memoryGiB: 4, diskGiB: 64,
                       extra: ["schemaVersion": 5, "controlledNetwork": controlled])
        let allow = policy ?? ["deb.debian.org", "registry.ollama.ai",
                               "dd20bb891979d25aebc8bec07b2b3bbc.r2.cloudflarestorage.com", "time.cloudflare.com"]
        let json = try JSONSerialization.data(withJSONObject: ["v": 1, "allow": allow], options: [.sortedKeys])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: bundleURL("debian-13").appendingPathComponent("egress.json").path, contents: json,
            attributes: [.posixPermissions: 0o600]))
        let now = Date()
        appendEgress([
            (-300, "allowed", "deb.debian.org", "151.101.2.132", 443, "tcp", ["bytesOut": 48_210, "bytesIn": 29_871_004, "count": 4]),
            (-240, "allowed", "registry.ollama.ai", "104.21.75.227", 443, "tcp", ["bytesOut": 9_120, "bytesIn": 412_330]),
            (-200, "name", "_https._tcp.deb.debian.org", nil, 53, "udp", [:]),
            (-120, "denyUnknown", nil, "203.0.113.9", 443, "tcp", [:]),
        ], at: now)
    }

    /// Lines in the VM's logs as the relay writes them (`EgressLog`): blocks in `egress.log`,
    /// allowed flows in `egress-flows.log`.
    func appendEgress(
        _ lines: [(Double, String, String?, String?, Int, String, [String: Any])], at now: Date
    ) {
        let iso = ISO8601DateFormatter()
        for line in lines {
            var entry: [String: Any] = ["time": iso.string(from: now.addingTimeInterval(line.0)), "verdict": line.1,
                                        "port": line.4, "proto": line.5, "bytesOut": 0, "bytesIn": 0]
            if let domain = line.2 { entry["domain"] = domain }
            if let ip = line.3 { entry["ip"] = ip }
            entry.merge(line.6) { _, new in new }
            let file = line.1 == "allowed" || line.1 == "open" ? "egress-flows.log" : "egress.log"
            let url = bundleURL("debian-13").appendingPathComponent(file)
            let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])) ?? Data()
            if !FileManager.default.fileExists(atPath: url.path) {
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil,
                                                             attributes: [.posixPermissions: 0o600]))
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return XCTFail("\(file) non apribile") }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }

    @MainActor
    func element(_ identifier: String, in parent: XCUIElement) -> XCUIElement {
        parent.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func libraryWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows["Nido"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "La finestra Nido non è comparsa")
        return window
    }

    func card(_ name: String, in window: XCUIElement) -> XCUIElement {
        let card = window.descendants(matching: .any).matching(identifier: name).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Manca la scheda di \(name)")
        return card
    }

    func waitForValue(of element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = element.value as? String, value.contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    // MARK: - Fixtures

    func bundleURL(_ name: String) -> URL {
        root.appendingPathComponent("\(name).nidovm", isDirectory: true)
    }

    /// A bundle with a valid config.json (the VMConfig schema, version 1).
    /// `suspended`: a saved state (`state.vzvmsave`) and its hash, as `nido stop --suspend` leaves them.
    func makeBundle(
        _ name: String, cpu: Int, memoryGiB: UInt64, diskGiB: UInt64, suspended: Bool = false,
        machineFiles: Bool = false, extra: [String: Any] = [:]
    ) throws {
        var config: [String: Any] = [
            "schemaVersion": 1, "id": UUID().uuidString, "name": name, "guest": "linux",
            "cpuCount": cpu, "memoryBytes": memoryGiB << 30, "diskBytes": diskGiB << 30,
            "macAddress": "52:54:00:12:34:56", "clipboardSharing": false,
        ]
        if suspended { config["suspendedConfigHash"] = "screenshot" }
        config.merge(extra) { _, new in new }
        try makeBundle(name, config: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
        if machineFiles {
            // Small stand-ins for the files a snapshot clones (disk, NVRAM, identity, seed).
            for file in ["disk.img", "nvram.efi", "machine-id.bin", "seed.iso"] {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: bundleURL(name).appendingPathComponent(file).path,
                    contents: Data(file.utf8), attributes: [.posixPermissions: 0o600]))
            }
        }
        if suspended {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: bundleURL(name).appendingPathComponent("state.vzvmsave").path,
                contents: Data("saved-state".utf8), attributes: [.posixPermissions: 0o600]))
        }
    }

    /// A stopped macOS bundle (schema 4) with small stand-ins for the files a clone copies.
    func makeMacBundle(_ name: String, diskGiB: UInt64) throws {
        let config: [String: Any] = [
            "schemaVersion": 4, "id": UUID().uuidString, "name": name, "guest": "macos",
            "cpuCount": 4, "memoryBytes": UInt64(8) << 30, "diskBytes": diskGiB << 30,
            "macAddress": "52:54:00:12:34:58", "clipboardSharing": false, "sshUser": "agente", "osVersion": "26.6",
        ]
        try makeBundle(name, config: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHk2Lw9QeXbT4mZr7Vd1cN8sJpFa3uYoG6tRqE0iWzK5 tu@mac\n"
        let files = ["disk.img": "disk", "auxiliary-storage.img": "aux", "hardware-model.bin": "hw",
                     "machine-id.bin": "id", "authorized_key.pub": key]
        for (file, contents) in files {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: bundleURL(name).appendingPathComponent(file).path,
                contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600]))
        }
    }

    func makeBundle(_ name: String, config: Data) throws {
        let url = bundleURL(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.appendingPathComponent("config.json").path, contents: config,
            attributes: [.posixPermissions: 0o600]))
    }

    /// A snapshot as `SnapshotStore` writes it: `snapshots/<uuid>/meta.json` (the list reads only that).
    func makeSnapshot(_ vm: String, _ name: String, _ date: String, savedState: Bool) throws {
        let snapshots = bundleURL(vm).appendingPathComponent("snapshots", isDirectory: true)
        let id = UUID()
        let directory = snapshots.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let meta: [String: Any] = ["id": id.uuidString, "name": name, "createdAt": date,
                                   "hasSavedState": savedState, "configHash": "screenshot"]
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("meta.json").path,
            contents: try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]),
            attributes: [.posixPermissions: 0o600]))
    }

    func removeSnapshots(_ vm: String) {
        try? FileManager.default.removeItem(at: bundleURL(vm).appendingPathComponent("snapshots"))
    }

    /// Removes the snapshot a test created, so the next appearance starts from the same list.
    func removeSnapshot(named name: String, of vm: String) {
        let snapshots = bundleURL(vm).appendingPathComponent("snapshots", isDirectory: true)
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [] {
            let meta = snapshots.appendingPathComponent(entry).appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: meta), String(decoding: data, as: UTF8.self).contains("\"\(name)\"") {
                try? FileManager.default.removeItem(at: snapshots.appendingPathComponent(entry))
            }
        }
    }

    /// Holds the bundle lock the way BundleLock does: flock on `.lock` with "<pid> <owner>\n".
    func holdLock(_ name: String, owner: String) throws {
        let path = bundleURL(name).appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let line = Array("\(getpid()) \(owner)\n".utf8)
        XCTAssertEqual(ftruncate(fd, 0), 0)
        XCTAssertEqual(line.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }, line.count)
        lockFDs.append(fd)
    }

    func releaseLocks() {
        for fd in lockFDs {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }
        lockFDs = []
    }
}
