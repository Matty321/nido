// SPDX-License-Identifier: Apache-2.0
import Compression
import Foundation
import Synchronization

/// Just enough qcow2 (versions 2 and 3) to turn a cloud image into the raw disk
/// Virtualization.framework boots: Ubuntu publishes its arm64 cloud images only as qcow2.
///
/// Read-only and self-contained (no `qemu-img`). Accepted: no backing file, no encryption,
/// standard L2 entries, uncompressed and zlib-compressed clusters, zero and unallocated clusters,
/// the `dirty` bit (only the refcounts may be stale; Nido never reads them). Refused with
/// `NidoError.unsupportedDiskImage`: a backing file, encryption, an external data file, extended
/// L2 entries, zstd compression, the `corrupt` bit, any unknown incompatible feature, any
/// offset or length outside the file, and tables that reference a cluster twice or describe far
/// more data than the file holds (`checkReferences`). Every table entry is bounds-checked: the
/// file may come from the user (`nido create --image-file`).
public enum Qcow2Image {
    /// `QFI\xfb`.
    static let magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]
    /// Largest virtual disk accepted (4 TiB): far above any cloud image, small enough that the
    /// raw file can never be absurd.
    public static let maxVirtualSize: UInt64 = 1 << 42
    /// Most L1 entries read (see `readHeader`).
    static let maxL1Entries: UInt64 = 1 << 20

    /// What the conversion needs from the header.
    struct Header: Equatable {
        var version: UInt32
        var clusterBits: UInt32
        var virtualSize: UInt64
        var l1Size: UInt32
        var l1Offset: UInt64

        var clusterSize: UInt64 { 1 << UInt64(clusterBits) }
        /// Entries in one L2 table (one cluster of 8-byte entries).
        var l2Entries: UInt64 { clusterSize / 8 }
        /// L1 entries needed to cover `virtualSize`.
        var neededL1Entries: UInt64 {
            let clusters = (virtualSize + clusterSize - 1) / clusterSize
            return (clusters + l2Entries - 1) / l2Entries
        }
    }

    /// True when the file starts with the qcow2 magic (a short or unreadable file is not qcow2).
    public static func isQcow2(_ url: URL) -> Bool {
        // O_NONBLOCK: a FIFO in place of the image must never hang the caller (the wizard).
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        var bytes = [UInt8](repeating: 0, count: 4)
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4, 0) }
        return count == 4 && bytes == magic
    }

    /// Size of the disk the image describes (the raw file `convert` writes).
    public static func virtualSize(of url: URL) throws -> UInt64 {
        let file = try SourceFile(url)
        defer { file.close() }
        return try readHeader(file).virtualSize
    }

    /// Writes the disk described by the qcow2 `source` as a sparse raw file at `destination`,
    /// which must not exist (created `0600`). Clusters that read as zeros are not written, so
    /// they stay holes. On any error, cancellation included, `destination` is removed.
    /// `isCancelled` is polled between batches of clusters (it throws `CancellationError`).
    public static func convert(
        _ source: URL, toRaw destination: URL, isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        let file = try SourceFile(source)
        defer { file.close() }
        let header = try readHeader(file)
        let l1 = try readL1(file, header)
        try checkReferences(file, header, l1: l1)

        let out = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var completed = false
        defer {
            _ = Darwin.close(out)
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        guard fchmod(out, 0o600) == 0, ftruncate(out, off_t(header.virtualSize)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // Jobs are slices of L2 tables, so a few huge L1 entries still spread over every core.
        let sliceEntries = min(header.l2Entries, 512)
        let slicesPerTable = header.l2Entries / sliceEntries
        let jobs = UInt64(l1.count) * slicesPerTable
        let failure = Mutex<(any Error)?>(nil)
        DispatchQueue.concurrentPerform(iterations: Int(jobs)) { index in
            guard failure.withLock({ $0 == nil }) else { return }
            do {
                if isCancelled() { throw CancellationError() }
                let job = UInt64(index)
                try convertSlice(
                    file: file, out: out, header: header, l2Offset: l1[Int(job / slicesPerTable)],
                    l1Index: job / slicesPerTable, firstEntry: (job % slicesPerTable) * sliceEntries,
                    count: sliceEntries)
            } catch {
                failure.withLock { if $0 == nil { $0 = error } }
            }
        }
        if let error = failure.withLock({ $0 }) { throw error }
        if isCancelled() { throw CancellationError() }
        guard fsync(out) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        completed = true
    }

    // MARK: - Header and L1

    static func readHeader(_ file: SourceFile) throws -> Header {
        let bytes = try file.read(count: 104, at: 0, outside: L10n.string("header outside the file"))
        guard Array(bytes[0..<4]) == magic else { throw NidoError.unsupportedDiskImage(L10n.string("not a qcow2 file")) }
        let version = be32(bytes, 4)
        guard version == 2 || version == 3 else {
            throw NidoError.unsupportedDiskImage(L10n.string("qcow2 version \(String(version))"))
        }
        guard be64(bytes, 8) == 0 else { throw NidoError.unsupportedDiskImage(L10n.string("qcow2 with a backing file")) }
        let clusterBits = be32(bytes, 20)
        guard (9...21).contains(clusterBits) else {
            throw NidoError.unsupportedDiskImage(L10n.string("invalid cluster size (\(Int(clusterBits)) bits)"))
        }
        let virtualSize = be64(bytes, 24)
        guard virtualSize > 0, virtualSize <= maxVirtualSize else {
            throw NidoError.unsupportedDiskImage(L10n.string("invalid disk size (\(String(virtualSize)) bytes)"))
        }
        guard be32(bytes, 32) == 0 else { throw NidoError.unsupportedDiskImage(L10n.string("encrypted qcow2")) }
        if version == 3 {
            let incompatible = be64(bytes, 72)
            // Bit 0 (dirty) is accepted: the refcounts may be stale, the tables read here are not.
            let known: UInt64 = 0b1_1111
            guard incompatible & ~known == 0 else {
                throw NidoError.unsupportedDiskImage(L10n.string("unknown qcow2 features (0x\(String(incompatible, radix: 16)))"))
            }
            guard incompatible & 0b10 == 0 else { throw NidoError.unsupportedDiskImage(L10n.string("qcow2 marked as corrupt")) }
            guard incompatible & 0b100 == 0 else { throw NidoError.unsupportedDiskImage(L10n.string("qcow2 with an external data file")) }
            guard incompatible & 0b1_0000 == 0 else { throw NidoError.unsupportedDiskImage(L10n.string("qcow2 with extended L2 entries")) }
            if incompatible & 0b1000 != 0 {
                let headerLength = be32(bytes, 100)
                guard headerLength > 104 else { throw NidoError.unsupportedDiskImage(L10n.string("truncated qcow2 header")) }
                let type = try file.read(count: 1, at: 104, outside: L10n.string("header outside the file"))[0]
                guard type == 0 else { throw NidoError.unsupportedDiskImage(L10n.string("unsupported qcow2 compression (type \(String(type)))")) }
            }
        }
        let header = Header(
            version: version, clusterBits: clusterBits, virtualSize: virtualSize,
            l1Size: be32(bytes, 36), l1Offset: be64(bytes, 40))
        guard UInt64(header.l1Size) >= header.neededL1Entries else {
            throw NidoError.unsupportedDiskImage(L10n.string("L1 table too short"))
        }
        // Real images need a few thousand entries (64 KiB clusters: 8192 for 4 TiB); tiny
        // clusters on a huge disk would mean millions of tiny jobs.
        guard header.neededL1Entries <= maxL1Entries else {
            throw NidoError.unsupportedDiskImage(L10n.string("L1 table too large"))
        }
        return header
    }

    /// The L2 table offsets of the entries covering the disk (0: unallocated).
    static func readL1(_ file: SourceFile, _ header: Header) throws -> [UInt64] {
        let count = Int(header.neededL1Entries)
        let bytes = try file.read(count: count * 8, at: header.l1Offset, outside: L10n.string("L1 table outside the file"))
        return try (0..<count).map { index in
            let offset = be64(bytes, index * 8) & offsetMask
            guard offset % header.clusterSize == 0 else {
                throw NidoError.unsupportedDiskImage(L10n.string("misaligned L2 table"))
            }
            return offset
        }
    }

    /// Bits 9–55 of an L1 entry and of a standard L2 entry.
    static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00

    // MARK: - References

    /// Most data an image may describe for each byte of its file: an average expansion no real
    /// image comes near (Ubuntu's cloud images are about 4×; a mostly empty file system with its
    /// bitmaps a few tens), well under deflate's own limit of about 1000×.
    static let maxExpansion: UInt64 = 64
    /// Data always allowed, whatever the file size (a tiny but genuine image).
    static let minDataBudget: UInt64 = 256 << 20

    /// Before writing anything: no L2 table and no data cluster may be referenced twice (in the
    /// tables of the disk, every cluster of a genuine image is used once), and the data clusters
    /// referenced may not exceed `maxExpansion` times the file. Otherwise a small file could
    /// expand into a disk full of written data (non-sparse), up to the virtual size.
    static func checkReferences(
        _ file: SourceFile, _ header: Header, l1: [UInt64],
        maxExpansion: UInt64 = maxExpansion, minDataBudget: UInt64 = minDataBudget
    ) throws {
        let clusterSize = header.clusterSize
        let totalClusters = (header.virtualSize + clusterSize - 1) / clusterSize
        let (product, overflow) = file.size.multipliedReportingOverflow(by: maxExpansion)
        let budget = max(overflow ? .max : product, minDataBudget)
        // L2 tables and data clusters share one set: a table reused as data is a repeat too. Only
        // offsets inside the file are inserted, so each set holds at most size / cluster (or size)
        // entries.
        var clusters = Set<UInt64>()
        var compressed = Set<UInt64>()
        var referenced: UInt64 = 0
        let x = 62 - (UInt64(header.clusterBits) - 8)
        for (index, l2Offset) in l1.enumerated() where l2Offset != 0 {
            guard l2Offset <= file.size, clusterSize <= file.size - l2Offset else {
                throw NidoError.unsupportedDiskImage(L10n.string("L2 table outside the file"))
            }
            guard clusters.insert(l2Offset).inserted else {
                throw NidoError.unsupportedDiskImage(L10n.string("L2 table used twice"))
            }
            let first = UInt64(index) * header.l2Entries
            guard first < totalClusters else { continue }
            let count = min(header.l2Entries, totalClusters - first)
            let table = try file.read(count: Int(count) * 8, at: l2Offset, outside: L10n.string("L2 table outside the file"))
            for entryIndex in 0..<Int(count) {
                let entry = be64(table, entryIndex * 8)
                if entry & (1 << 62) != 0 {
                    let start = entry & ((1 << x) - 1)
                    guard start < file.size else {
                        throw NidoError.unsupportedDiskImage(L10n.string("compressed cluster outside the file"))
                    }
                    guard compressed.insert(start).inserted else {
                        throw NidoError.unsupportedDiskImage(L10n.string("compressed cluster used twice"))
                    }
                } else {
                    let hostOffset = entry & offsetMask
                    if (header.version >= 3 && entry & 1 != 0) || hostOffset == 0 { continue }
                    guard hostOffset % clusterSize == 0 else {
                        throw NidoError.unsupportedDiskImage(L10n.string("misaligned cluster"))
                    }
                    guard hostOffset <= file.size, clusterSize <= file.size - hostOffset else {
                        throw NidoError.unsupportedDiskImage(L10n.string("cluster outside the file"))
                    }
                    guard clusters.insert(hostOffset).inserted else {
                        throw NidoError.unsupportedDiskImage(L10n.string("cluster used twice"))
                    }
                }
                referenced += clusterSize
                guard referenced <= budget else {
                    throw NidoError.unsupportedDiskImage(L10n.string("data out of proportion to the file size"))
                }
            }
        }
    }

    // MARK: - Clusters

    /// Converts `count` L2 entries from `firstEntry` of the table at `l2Offset`.
    private static func convertSlice(
        file: SourceFile, out: Int32, header: Header, l2Offset: UInt64, l1Index: UInt64,
        firstEntry: UInt64, count: UInt64
    ) throws {
        guard l2Offset != 0 else { return }
        let clusterSize = header.clusterSize
        let firstCluster = l1Index * header.l2Entries + firstEntry
        let totalClusters = (header.virtualSize + clusterSize - 1) / clusterSize
        guard firstCluster < totalClusters else { return }
        let entries = min(count, totalClusters - firstCluster)
        let table = try file.read(count: Int(entries) * 8, at: l2Offset + firstEntry * 8, outside: L10n.string("L2 table outside the file"))
        var cluster = [UInt8](repeating: 0, count: Int(clusterSize))
        for index in 0..<Int(entries) {
            let entry = be64(table, index * 8)
            let guestOffset = (firstCluster + UInt64(index)) * clusterSize
            guard try readCluster(entry, file: file, header: header, into: &cluster) else { continue }
            if cluster.allSatisfy({ $0 == 0 }) { continue }
            let length = Int(min(clusterSize, header.virtualSize - guestOffset))
            try writeAll(out, cluster, length: length, at: guestOffset)
        }
    }

    /// Reads the cluster `entry` points to into `buffer`; false when it reads as zeros.
    static func readCluster(_ entry: UInt64, file: SourceFile, header: Header, into buffer: inout [UInt8]) throws -> Bool {
        let clusterSize = header.clusterSize
        if entry & (1 << 62) != 0 {
            // Compressed: offset in bits 0..<x, extra 512-byte sectors in bits x...61.
            let x = 62 - (UInt64(header.clusterBits) - 8)
            let hostOffset = entry & ((1 << x) - 1)
            let extraSectors = (entry >> x) & ((1 << (62 - x)) - 1)
            let declared = (extraSectors + 1) * 512 - (hostOffset & 511)
            // Never more than a cluster plus its sector slack; the last one may end with the file.
            let length = min(declared, clusterSize + 1024, file.size > hostOffset ? file.size - hostOffset : 0)
            guard length > 0 else { throw NidoError.unsupportedDiskImage(L10n.string("compressed cluster outside the file")) }
            let compressed = try file.read(count: Int(length), at: hostOffset, outside: L10n.string("compressed cluster outside the file"))
            let produced = compressed.withUnsafeBufferPointer { src in
                buffer.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(
                        dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard produced == buffer.count else { throw NidoError.unsupportedDiskImage(L10n.string("unreadable compressed cluster")) }
            return true
        }
        let hostOffset = entry & offsetMask
        // Bit 0 (v3): the cluster reads as zeros whatever it points to. Offset 0: unallocated,
        // and with no backing file it reads as zeros too.
        if (header.version >= 3 && entry & 1 != 0) || hostOffset == 0 { return false }
        guard hostOffset % clusterSize == 0 else { throw NidoError.unsupportedDiskImage(L10n.string("misaligned cluster")) }
        let data = try file.read(count: Int(clusterSize), at: hostOffset, outside: L10n.string("cluster outside the file"))
        buffer.withUnsafeMutableBytes { dst in data.withUnsafeBytes { dst.copyMemory(from: $0) } }
        return true
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], length: Int, at offset: UInt64) throws {
        var written = 0
        while written < length {
            let count = bytes.withUnsafeBytes {
                pwrite(fd, $0.baseAddress! + written, length - written, off_t(offset) + off_t(written))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += count
        }
    }

    // MARK: - Source file

    /// The qcow2 file, opened once without following a symlink; `pread` only, so the workers share it.
    final class SourceFile: Sendable {
        let fd: Int32
        let size: UInt64

        init(_ url: URL) throws {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw NidoError.notFound(url.path) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                _ = Darwin.close(fd)
                throw NidoError.notFound(url.path)
            }
            self.fd = fd
            self.size = UInt64(info.st_size)
        }

        func close() { _ = Darwin.close(fd) }

        /// Exactly `count` bytes at `offset`; anything outside the file is
        /// `.unsupportedDiskImage(outside())`, the localized reason (built only on failure).
        func read(count: Int, at offset: UInt64, outside: @autoclosure () -> String) throws -> [UInt8] {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
                throw NidoError.unsupportedDiskImage(outside())
            }
            var bytes = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                let n = bytes.withUnsafeMutableBytes {
                    pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else {
                    if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    throw NidoError.unsupportedDiskImage(outside())
                }
                done += n
            }
            return bytes
        }
    }

    // MARK: - Big-endian fields

    static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
