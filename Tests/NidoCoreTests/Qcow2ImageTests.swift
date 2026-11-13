// SPDX-License-Identifier: Apache-2.0
import Compression
import Foundation
import Testing
@testable import NidoCore

/// Synthetic qcow2 files: 512-byte clusters (cluster 0 the header, 1 the L1 table, 2 the L2
/// table, 3 an uncompressed data cluster, then the compressed data), four guest clusters:
/// data `A`, compressed `B`, a zero-flagged cluster pointing at the `A` data, and an unallocated one.
@Suite(.italian) struct Qcow2ImageTests {
    static let clusterSize = 512

    struct Fixture {
        var version: UInt32 = 3
        var backingFileOffset: UInt64 = 0
        var cryptMethod: UInt32 = 0
        var incompatible: UInt64 = 0
        var compressionType: UInt8 = 0
        var virtualSize: UInt64 = 4 * 512
        var l1Size: UInt32 = 1
        var l2Offset: UInt64 = 1024
        /// Replaces entry 0 of the L2 table when set.
        var firstEntry: UInt64?
        /// Replaces entry 2 (the zero-flagged one) when set.
        var thirdEntry: UInt64?
        /// L1 entry 1, when set (needs `l1Size` 2 and a disk over one L2 table).
        var secondL1: UInt64?

        func bytes() -> [UInt8] {
            let cluster = Qcow2ImageTests.clusterSize
            var file = [UInt8](repeating: 0, count: 4 * cluster)
            func put32(_ value: UInt32, _ at: Int) { for i in 0..<4 { file[at + i] = UInt8(value >> (24 - 8 * i) & 0xFF) } }
            func put64(_ value: UInt64, _ at: Int) { for i in 0..<8 { file[at + i] = UInt8(value >> (56 - 8 * i) & 0xFF) } }
            file[0..<4] = [0x51, 0x46, 0x49, 0xFB]
            put32(version, 4)
            put64(backingFileOffset, 8)
            put32(9, 20)  // 512-byte clusters
            put64(virtualSize, 24)
            put32(cryptMethod, 32)
            put32(l1Size, 36)
            put64(512, 40)  // L1 table
            if version == 3 {
                put64(incompatible, 72)
                put32(incompatible & 0b1000 != 0 ? 112 : 104, 100)
                file[104] = compressionType
            }
            put64(l2Offset | 1 << 63, 512)
            if let secondL1 { put64(secondL1 | 1 << 63, 520) }

            // Data cluster `A` at 1536, compressed `B` right after the four clusters.
            for i in 0..<cluster { file[3 * cluster + i] = UInt8(ascii: "A") }
            let compressed = Self.deflate([UInt8](repeating: UInt8(ascii: "B"), count: cluster))
            let compressedOffset = UInt64(file.count)
            file += compressed
            // x = 62 - (9 - 8) = 61: offset in bits 0..<61, extra sectors in bit 61 (none here).
            precondition(compressed.count <= 512)
            let entries: [UInt64] = [
                firstEntry ?? (UInt64(3 * cluster) | 1 << 63),
                1 << 62 | compressedOffset,
                thirdEntry ?? (UInt64(3 * cluster) | 1),  // zero flag: reads as zeros despite pointing at `A`
                0,  // unallocated
            ]
            for (i, entry) in entries.enumerated() { put64(entry, 2 * cluster + i * 8) }
            return file
        }

        static func deflate(_ input: [UInt8]) -> [UInt8] {
            var output = [UInt8](repeating: 0, count: input.count + 64)
            let count = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
            precondition(count > 0)
            return Array(output[..<count])
        }
    }

    func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nido-qcow2test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ fixture: Fixture, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("image.qcow2")
        try Data(fixture.bytes()).write(to: url)
        return url
    }

    @Test func convertsDataCompressedZeroAndUnallocatedClusters() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(), in: tmp)
        let raw = tmp.appendingPathComponent("disk.raw")
        try Qcow2Image.convert(source, toRaw: raw)
        let bytes = [UInt8](try Data(contentsOf: raw))
        let cluster = Self.clusterSize
        #expect(bytes.count == 4 * cluster)
        #expect(bytes[0..<cluster].allSatisfy { $0 == UInt8(ascii: "A") })
        #expect(bytes[cluster..<(2 * cluster)].allSatisfy { $0 == UInt8(ascii: "B") })
        #expect(bytes[(2 * cluster)...].allSatisfy { $0 == 0 })
        let mode = try FileManager.default.attributesOfItem(atPath: raw.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func version2HasNoZeroFlag() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        // In v2, bit 0 is not a zero flag: the cluster is read from its offset (here the L1
        // table's cluster, the only other one with data).
        let fixture = Fixture(version: 2, thirdEntry: 512 | 1)
        let source = try write(fixture, in: tmp)
        let raw = tmp.appendingPathComponent("disk.raw")
        try Qcow2Image.convert(source, toRaw: raw)
        let bytes = [UInt8](try Data(contentsOf: raw))
        #expect(bytes[(2 * Self.clusterSize)..<(3 * Self.clusterSize)] == fixture.bytes()[512..<1024])
    }

    @Test func budgetLimitsTheDataATinyFileMayDescribe() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(), in: tmp)
        let file = try Qcow2Image.SourceFile(source)
        defer { file.close() }
        let header = try Qcow2Image.readHeader(file)
        let l1 = try Qcow2Image.readL1(file, header)
        // Two data clusters (1 KiB): within any budget of at least that.
        try Qcow2Image.checkReferences(file, header, l1: l1, maxExpansion: 0, minDataBudget: 1024)
        #expect(throws: NidoError.unsupportedDiskImage("dati sproporzionati rispetto alla dimensione del file")) {
            try Qcow2Image.checkReferences(file, header, l1: l1, maxExpansion: 0, minDataBudget: 1023)
        }
        // The real limits leave room for every genuine image.
        #expect(Qcow2Image.maxExpansion == 64)
        #expect(Qcow2Image.minDataBudget == 256 << 20)
    }

    @Test func dirtyBitIsAccepted() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(incompatible: 0b1), in: tmp)
        try Qcow2Image.convert(source, toRaw: tmp.appendingPathComponent("disk.raw"))
    }

    @Test func zlibCompressionTypeIsAccepted() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(incompatible: 0b1000, compressionType: 0), in: tmp)
        try Qcow2Image.convert(source, toRaw: tmp.appendingPathComponent("disk.raw"))
    }

    @Test func virtualSizeAndDetection() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(), in: tmp)
        #expect(Qcow2Image.isQcow2(source))
        #expect(try Qcow2Image.virtualSize(of: source) == 2048)
        let raw = tmp.appendingPathComponent("plain.raw")
        try Data(repeating: 0, count: 4096).write(to: raw)
        #expect(!Qcow2Image.isQcow2(raw))
        #expect(!Qcow2Image.isQcow2(tmp.appendingPathComponent("missing")))
    }

    static let refused: [(Fixture, String)] = [
        (Fixture(backingFileOffset: 4096), "qcow2 con file di base (backing file)"),
        (Fixture(cryptMethod: 1), "qcow2 cifrato"),
        (Fixture(version: 4), "qcow2 versione 4"),
        (Fixture(incompatible: 0b10), "qcow2 segnato come danneggiato"),
        (Fixture(incompatible: 0b100), "qcow2 con file dati esterno"),
        (Fixture(incompatible: 0b1_0000), "qcow2 con voci L2 estese"),
        (Fixture(incompatible: 0b10_0000), "funzioni qcow2 sconosciute (0x20)"),
        (Fixture(incompatible: 0b1000, compressionType: 1), "compressione qcow2 non supportata (tipo 1)"),
        (Fixture(virtualSize: 0), "dimensione del disco non valida (0 byte)"),
        (Fixture(virtualSize: Qcow2Image.maxVirtualSize + 512),
         "dimensione del disco non valida (\(Qcow2Image.maxVirtualSize + 512) byte)"),
        (Fixture(virtualSize: 64 * 512 + 512), "tabella L1 troppo corta"),
        // 512-byte clusters: one L2 table covers 32 KiB, so 64 GiB needs 2^21 L1 entries.
        (Fixture(virtualSize: 64 << 30, l1Size: 1 << 21), "tabella L1 troppo grande"),
        (Fixture(l2Offset: 1 << 20), "tabella L2 fuori dal file"),
        // A cluster referenced twice: in v2 entry 2 reads `A` again.
        (Fixture(version: 2), "cluster usato due volte"),
        (Fixture(firstEntry: 1 << 62 | 2048), "cluster compresso usato due volte"),
        // The L2 table itself used as a data cluster.
        (Fixture(firstEntry: 1024 | 1 << 63), "cluster usato due volte"),
        (Fixture(firstEntry: 1 << 62 | 1 << 20), "cluster compresso fuori dal file"),
        (Fixture(virtualSize: 65 * 512, l1Size: 2, secondL1: 1024), "tabella L2 usata due volte"),
        (Fixture(firstEntry: 1 << 20 | 1 << 63), "cluster fuori dal file"),
    ]

    @Test(arguments: 0..<refused.count)
    func refusesWhatItCannotRead(_ index: Int) throws {
        let (fixture, reason) = Self.refused[index]
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(fixture, in: tmp)
        let raw = tmp.appendingPathComponent("disk.raw")
        #expect(throws: NidoError.unsupportedDiskImage(reason)) {
            try Qcow2Image.convert(source, toRaw: raw)
        }
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func corruptCompressedClusterIsRefusedAndLeavesNothing() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        var bytes = Fixture().bytes()
        for i in (4 * Self.clusterSize)..<bytes.count { bytes[i] = 0xFF }
        let source = tmp.appendingPathComponent("image.qcow2")
        try Data(bytes).write(to: source)
        let raw = tmp.appendingPathComponent("disk.raw")
        #expect(throws: NidoError.unsupportedDiskImage("cluster compresso illeggibile")) {
            try Qcow2Image.convert(source, toRaw: raw)
        }
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func existingDestinationIsNeverOverwritten() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(), in: tmp)
        let raw = tmp.appendingPathComponent("disk.raw")
        try Data("keep".utf8).write(to: raw)
        #expect(throws: POSIXError.self) { try Qcow2Image.convert(source, toRaw: raw) }
        #expect(try Data(contentsOf: raw) == Data("keep".utf8))
    }

    @Test func cancellationLeavesNothing() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(), in: tmp)
        let raw = tmp.appendingPathComponent("disk.raw")
        #expect(throws: CancellationError.self) {
            try Qcow2Image.convert(source, toRaw: raw, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func fifoIsNeverReadAsAnImage() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let fifo = tmp.appendingPathComponent("fifo.img")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(!Qcow2Image.isQcow2(fifo))
        #expect(throws: NidoError.notFound(fifo.path)) {
            try Qcow2Image.convert(fifo, toRaw: tmp.appendingPathComponent("disk.raw"))
        }
    }

    @Test func symlinkedSourceIsRefused() throws {
        let tmp = try makeTemp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try write(Fixture(), in: tmp)
        let link = tmp.appendingPathComponent("link.qcow2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(!Qcow2Image.isQcow2(link))
        #expect(throws: NidoError.notFound(link.path)) {
            try Qcow2Image.convert(link, toRaw: tmp.appendingPathComponent("disk.raw"))
        }
    }
}
