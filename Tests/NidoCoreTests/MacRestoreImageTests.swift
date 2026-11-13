// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// Returns a fixed image (or error) and counts its calls.
private struct FakeLoader: MacRestoreImageLoading {
    let result: Result<LoadedMacRestoreImage, FakeLoadError>
    let calls = LoadCallCounter()

    func load(_ url: URL) async throws -> LoadedMacRestoreImage {
        calls.increment()
        return try result.get()
    }
}

private struct FakeLoadError: Error {}

private final class LoadCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private func image(
    major: Int = 26, minor: Int = 1, patch: Int = 0, build: String = "25B78",
    imageSupported: Bool = true,
    configuration: LoadedMacRestoreImage.Requirements? = .init(
        hardwareModelSupported: true, hardwareModel: Data([1, 2, 3]),
        minimumCPUCount: 2, minimumMemoryBytes: 4 << 30)
) -> LoadedMacRestoreImage {
    LoadedMacRestoreImage(
        buildVersion: build,
        operatingSystemVersion: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch),
        isSupported: imageSupported, configuration: configuration)
}

private let host26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 1)

@Suite(.italian) struct MacRestoreImageTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A file that starts like a ZIP archive (an IPSW is one): enough to reach the loader.
    private func fakeIPSW(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("UniversalMac_26.1_25B78_Restore.ipsw")
        try Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 60)).write(to: url)
        return url
    }

    private func inspectError(
        _ url: URL, _ loader: FakeLoader, host: OperatingSystemVersion = host26
    ) async -> NidoError? {
        do {
            _ = try await MacRestoreImage.inspect(url, loader: loader, hostVersion: host)
            return nil
        } catch {
            return error
        }
    }

    @Test func inspectRejectsNonIPSW() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("note.ipsw")
        try Data("not a restore image\n".utf8).write(to: text)
        let loader = FakeLoader(result: .success(image()))
        let error = await inspectError(text, loader)
        #expect(error == .notARestoreImage(text.path))
        #expect(loader.calls.count == 0)
        #expect(error?.errorDescription == "\(text.path) non è un'immagine di ripristino macOS (IPSW) valida")
        // A directory, an empty file and a missing file are refused the same way (missing: not found).
        #expect(await inspectError(dir, loader) == .notARestoreImage(dir.path))
        let empty = dir.appendingPathComponent("empty.ipsw")
        try Data().write(to: empty)
        #expect(await inspectError(empty, loader) == .notARestoreImage(empty.path))
        let missing = dir.appendingPathComponent("missing.ipsw")
        #expect(await inspectError(missing, loader) == .notFound(missing.path))
        // A FIFO is refused without blocking.
        let fifo = dir.appendingPathComponent("fifo.ipsw")
        try makeFIFO(fifo)
        #expect(await inspectError(fifo, loader) == .notARestoreImage(fifo.path))
        #expect(loader.calls.count == 0)
    }

    @Test func inspectMapsLoaderFailureToNotARestoreImage() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fakeIPSW(in: dir)
        let loader = FakeLoader(result: .failure(FakeLoadError()))
        #expect(await inspectError(url, loader) == .notARestoreImage(url.path))
        #expect(loader.calls.count == 1)
    }

    @Test func inspectRefusesSymlink() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = try fakeIPSW(in: dir)
        let link = dir.appendingPathComponent("link.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let loader = FakeLoader(result: .success(image()))
        #expect(await inspectError(link, loader) == .unsafePath(link.path))
        #expect(loader.calls.count == 0)
    }

    @Test func inspectRejectsNewerMajor() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fakeIPSW(in: dir)
        // Even when Virtualization reports a configuration, a newer major than the host is refused.
        for loaded in [image(major: 27, minor: 0), image(major: 27, minor: 0, configuration: nil)] {
            let error = await inspectError(url, FakeLoader(result: .success(loaded)))
            #expect(error == .restoreImageUnsupported(version: "27.0", requiredHostMajor: 27))
            let text = try #require(error?.errorDescription)
            #expect(text.contains("serve un Mac con macOS 27"))
            #expect(text == "macOS 27.0 non si può installare in una VM su questo Mac: serve un Mac con macOS 27 o successivo")
        }
        // The same image on a host of that major is accepted.
        let host27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        let info = try await MacRestoreImage.inspect(
            url, loader: FakeLoader(result: .success(image(major: 27, minor: 0))), hostVersion: host27)
        #expect(info.version == "27.0")
    }

    @Test func inspectRejectsNoSupportedConfiguration() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fakeIPSW(in: dir)
        let unsupportedModel = LoadedMacRestoreImage.Requirements(
            hardwareModelSupported: false, hardwareModel: Data([9]), minimumCPUCount: 2, minimumMemoryBytes: 4 << 30)
        for loaded in [image(configuration: nil), image(imageSupported: false),
                       image(configuration: unsupportedModel)] {
            let error = await inspectError(url, FakeLoader(result: .success(loaded)))
            #expect(error == .restoreImageUnsupported(version: "26.1"))
            #expect(error?.errorDescription == "macOS 26.1 non è supportato da Virtualization su questo Mac")
        }
    }

    @Test func inspectReturnsMinimums() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try fakeIPSW(in: dir)
        let loader = FakeLoader(result: .success(image(major: 26, minor: 0, patch: 1, build: "25A362")))
        let info = try await MacRestoreImage.inspect(url, loader: loader, hostVersion: host26)
        #expect(info == MacImageInfo(
            buildVersion: "25A362", version: "26.0.1", minimumCPUCount: 2,
            minimumMemoryBytes: 4 << 30, hardwareModel: Data([1, 2, 3])))
        #expect(loader.calls.count == 1)
        let plain = try await MacRestoreImage.inspect(
            url, loader: FakeLoader(result: .success(image())), hostVersion: host26)
        #expect(plain.version == "26.1")
    }
}
