// SPDX-License-Identifier: Apache-2.0
import Foundation
import NidoCore

/// Lists the VMs with their live status (`VMRegistry` in the app, a fake in the tests).
protocol VMRegistryProviding: Sendable {
    func summaries() async throws -> [VMSummary]
}

extension VMRegistry: VMRegistryProviding {}

/// Stops and deletes VMs (`LiveVMControl` in the app, a fake in the tests).
protocol VMControlling: Sendable {
    /// SIGTERM to the `nido` process running the VM; refuses a VM run by the app.
    func requestStop(_ name: VMName) throws
    /// Removes the bundle; refuses a running VM.
    func delete(_ name: VMName) async throws
}

/// `VMControlling` on top of `VMControl`, for the VMs in `paths`.
struct LiveVMControl: VMControlling {
    let paths: NidoPaths

    func requestStop(_ name: VMName) throws {
        try VMControl.requestStop(bundle: VMBundle.open(name, paths: paths), name: name)
    }

    /// Off the main actor (the rename and the removal touch the disk); the lock's retries wait
    /// without blocking a thread.
    @concurrent
    func delete(_ name: VMName) async throws {
        try await VMControl.deleteVMAsync(name, paths: paths, owner: .app)
    }
}

/// Clones stopped VMs (`LiveVMCloner` in the app, a fake in the tests).
protocol VMCloning: Sendable {
    /// Copies the stopped VM `source` as the new VM `target` (`VMCloner`); returns what the user
    /// still runs in the copy (`VMCloner.cloneNotes`: empty for Linux).
    func clone(_ source: VMName, as target: VMName) async throws -> [String]
    /// "Nuova VM…" of a template: a new VM from it with a new identity, the template's key, no
    /// shared folders and the AI bridge off (`VMCloner.createFromTemplate`).
    func createFromTemplate(_ template: VMName, as target: VMName) async throws
}

/// `VMCloning` on top of `VMCloner`, for the VMs in `paths`: lock owner `.app`, taken without
/// blocking; the copy and the seed build run off the main actor.
struct LiveVMCloner: VMCloning {
    let paths: NidoPaths

    @concurrent
    func clone(_ source: VMName, as target: VMName) async throws -> [String] {
        try await VMCloner(paths: paths, runner: SystemProcessRunner())
            .cloneReportingNotes(source, as: target, owner: .app).cloneNotes
    }

    @concurrent
    func createFromTemplate(_ template: VMName, as target: VMName) async throws {
        _ = try await VMCloner(paths: paths, runner: SystemProcessRunner())
            .createFromTemplate(template, as: target, sshKeyPath: nil, owner: .app)
    }
}

/// Saves stopped VMs as templates and makes templates startable again (`LiveVMTemplates` in the
/// app, a fake in the tests).
protocol VMTemplating: Sendable {
    /// "Salva come modello": refused for a running VM or one with a suspended state.
    func save(_ name: VMName) async throws
    /// "Modifica modello": the template becomes a VM that starts again.
    func edit(_ name: VMName) async throws
}

/// `VMTemplating` on top of `VMTemplates`, lock owner `.app`, off the main actor.
struct LiveVMTemplates: VMTemplating {
    let paths: NidoPaths

    @concurrent
    func save(_ name: VMName) async throws {
        try VMTemplates.save(try VMBundle.open(name, paths: paths), owner: .app)
    }

    @concurrent
    func edit(_ name: VMName) async throws {
        try VMTemplates.edit(try VMBundle.open(name, paths: paths), owner: .app)
    }

    /// The space the template's bundle takes on the Mac (allocated sizes of its files), off the
    /// main actor; nil when it cannot be read.
    nonisolated static func allocatedBytes(of name: String, paths: NidoPaths) -> UInt64? {
        guard let vmName = try? VMName(name) else { return nil }
        let url = paths.bundleURL(for: vmName)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return nil }
        var total: UInt64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(max(0, values.totalFileAllocatedSize ?? 0))
        }
        return total
    }
}
