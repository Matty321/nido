// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NidoAgentKit

/// The bytes of a file an agent copies into or out of the VM (`putFile`, `getFile`) on their way
/// between a client (`nido act`, `nido mcp`) and the VM's owner. The control socket carries JSON
/// lines of at most 64 KiB, so the bytes never travel in it: like screenshots (`AgentShots`) they
/// are staged in the private bundle, in `<bundle>/agent-files/` (0700, files 0600), and the line
/// carries only the staged file's name.
///
/// A name is the one thing a forged client controls, so only `<lowercase UUID>.bin` names a
/// staged file, and `take` opens it from the folder's own descriptor without following a
/// symlink, as a regular file of this user with one link, at most `AgentProtocol.maxTransferBytes`.
/// Whoever reads a staged file deletes it, and the owner deletes a `getFile` answer's file when the
/// client is gone before the answer. Anything left over (a client that died after the answer, an
/// owner that crashed) is deleted once older than `maxAge` by the next transfer's `stage`, or when
/// the VM's control socket starts or stops. A clone or a VM made from a template never copies it.
public enum AgentFiles {
    /// How long a staged file may stay, in seconds.
    public static let maxAge: TimeInterval = 600

    /// Whether `name` is a staged file's name: a lowercase UUID followed by `.bin`, nothing else.
    public static func isStagedName(_ name: String) -> Bool {
        guard name.hasSuffix(".bin") else { return false }
        let stem = String(name.dropLast(4))
        guard let uuid = UUID(uuidString: stem) else { return false }
        return uuid.uuidString.lowercased() == stem
    }

    /// Writes `data` (at most `AgentProtocol.maxTransferBytes`) as a new staged file and returns
    /// its name, after deleting the staged files older than `maxAge`. The folder is created 0700
    /// when missing and refused (`.unsafePath`) when it is a symlink or not a folder.
    public static func stage(_ data: Data, in bundle: VMBundle) throws -> String {
        guard data.count <= AgentProtocol.maxTransferBytes else {
            throw NidoError.unsafePath(bundle.agentFilesURL.path)
        }
        let directory = bundle.agentFilesURL
        try PrivateDirectory.ensure(directory)
        // `ensure` checks the owner, not the type: a symlink planted there is refused here.
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NidoError.unsafePath(directory.path)
        }
        sweep(in: bundle, olderThan: maxAge)
        let name = UUID().uuidString.lowercased() + ".bin"
        try PrivateFile.writeAtomically(data, to: directory.appendingPathComponent(name))
        return name
    }

    /// The bytes of the staged file `name`, deleted once opened (also when it is then refused).
    /// Throws `.unsafePath` for a name that is not a staged file's, a folder that is a symlink, a
    /// file that is a symlink, a hard link, not a regular file, someone else's or larger than
    /// `AgentProtocol.maxTransferBytes`; a `POSIXError` for one that is missing or unreadable.
    public static func take(_ name: String, in bundle: VMBundle) throws -> Data {
        guard isStagedName(name) else { throw NidoError.unsafePath(name) }
        let folder = try openFolder(bundle)
        defer { _ = Darwin.close(folder) }
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { _ = unlinkat(folder, name, 0) }  // a planted symlink: removed, never followed
            throw code == ELOOP ? NidoError.unsafePath(name) : posixError(code)
        }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        let stated = fstat(fd, &info) == 0
        let code = errno
        // Whatever it turns out to be, it is read at most once.
        _ = unlinkat(folder, name, 0)
        guard stated else { throw posixError(code) }
        // One link, counted before the unlink: a hard link to another file has two.
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
            info.st_size >= 0, info.st_size <= off_t(AgentProtocol.maxTransferBytes)
        else { throw NidoError.unsafePath(name) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw posixError(errno) }
        return try readAll(fd, limit: AgentProtocol.maxTransferBytes, label: name)
    }

    /// Deletes `name` if it is a staged file's name (a client cleaning up what the owner did not
    /// take); never anything else.
    public static func remove(_ name: String, in bundle: VMBundle) {
        guard isStagedName(name), let folder = try? openFolder(bundle) else { return }
        _ = unlinkat(folder, name, 0)
        _ = Darwin.close(folder)
    }

    /// Deletes every file in the staging folder (staged files and temporary files of an
    /// interrupted write alike) last modified more than `age` seconds before `now`. Folders
    /// are left alone; a missing or unsafe staging folder is not touched.
    public static func sweep(in bundle: VMBundle, olderThan age: TimeInterval, now: Date = Date()) {
        guard let folder = try? openFolder(bundle) else { return }
        defer { _ = Darwin.close(folder) }
        let limit = now.timeIntervalSince1970 - age
        let duplicate = dup(folder)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            return
        }
        defer { closedir(stream) }
        var old: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) != S_IFDIR else {
                continue
            }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if modified < limit { old.append(name) }
        }
        for name in old { _ = unlinkat(folder, name, 0) }
    }

    // MARK: - Private

    /// The staging folder's descriptor: a real folder of this user, never through a symlink.
    private static func openFolder(_ bundle: VMBundle) throws -> Int32 {
        let path = bundle.agentFilesURL.path
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            throw code == ELOOP || code == ENOTDIR ? NidoError.unsafePath(path) : posixError(code)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            _ = Darwin.close(fd)
            throw NidoError.unsafePath(path)
        }
        return fd
    }

    /// Reads `fd` to its end, refusing more than `limit` bytes (a file that grew after `fstat`).
    private static func readAll(_ fd: Int32, limit: Int, label: String) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            if n == 0 { return data }
            guard data.count + n <= limit else { throw NidoError.unsafePath(label) }
            data.append(contentsOf: chunk[..<n])
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
