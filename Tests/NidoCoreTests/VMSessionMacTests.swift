// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import Virtualization
@testable import NidoCore

/// `VMSession` on a macOS bundle (`MacFixture`: the files `MacInstaller` leaves, without an
/// installed system). Building the machine needs the virtualization entitlement, which `swift
/// test` lacks: those tests are skipped there; the file checks run everywhere.
@Suite struct VMSessionMacTests {
    /// Both inits check the macOS file set (auxiliary storage, hardware model), not Linux's
    /// (`nvram.efi`, `seed.iso`, which a macOS bundle never has).
    @MainActor
    @Test func macSessionChecksTheMacFileSet() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let cache = f.tmp.appendingPathComponent("cache")
        let moved = f.tmp.appendingPathComponent("aux-elsewhere.img")
        try FileManager.default.moveItem(at: f.bundle.auxiliaryStorageURL, to: moved)
        try FileManager.default.createSymbolicLink(at: f.bundle.auxiliaryStorageURL, withDestinationURL: moved)
        #expect(throws: NidoError.unsafePath(f.bundle.auxiliaryStorageURL.path)) {
            _ = try VMSession(bundle: f.bundle, imageCache: cache)
        }
        #expect(throws: NidoError.unsafePath(f.bundle.auxiliaryStorageURL.path)) {
            _ = try VMSession(bundle: f.bundle, serialConsole: nil, imageCache: cache)
        }
        // Nothing was opened for a console.
        #expect(!FileManager.default.fileExists(atPath: f.bundle.consoleLogURL.path))
    }

    @MainActor
    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    func macSessionHasNoSerialConsole() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let cache = f.tmp.appendingPathComponent("cache")
        // `mirrorsConsole` has nothing to mirror on macOS (`nido start --console` is refused first).
        let cli = try VMSession(bundle: f.bundle, mirrorsConsole: true, imageCache: cache)
        #expect(cli.guest == .macos)
        #expect(cli.serialConsole == nil)
        #expect(cli.socketDevice == nil)
        #expect(cli.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.bundle.consoleLogURL.path))

        let app = try VMSession(bundle: f.bundle, serialConsole: nil, imageCache: cache)
        #expect(app.guest == .macos)
        #expect(app.serialConsole == nil)
        #expect(app.socketDevice == nil)
        #expect(app.attachedStateHash == f.config.effectiveStateHash(attachedShareNames: [], rosettaAttached: false))
    }

    /// Live shared-folder changes use the macOS automount device, not Linux's `nido` tag.
    @MainActor
    @Test(.enabled(if: canCreateVirtualMachines, "needs the virtualization entitlement"))
    func macSessionUpdatesSharedFoldersOnTheAutomountDevice() throws {
        let f = try MacFixture()
        defer { f.cleanup() }
        let docs = try f.folder("docs")
        let session = try VMSession(bundle: f.bundle, imageCache: f.tmp.appendingPathComponent("cache"))
        let warnings = try session.updateSharedFolders([SharedFolder(name: "docs", hostPath: docs.path, readOnly: true)])
        #expect(warnings.isEmpty)
        let device = try #require(session.virtualMachine.directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDevice }
            .first { $0.tag == MacConfigurationBuilder.sharedFolderTag })
        #expect((device.share as? VZMultipleDirectoryShare)?.directories.keys.sorted() == ["docs"])
    }
}
