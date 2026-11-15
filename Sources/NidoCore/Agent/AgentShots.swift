// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// The screenshots an agent takes, kept in `<bundle>/agent-shots/` (0700) as 0600 PNGs. The
/// guest's screen can show anything the user has open, so the files stay inside the private
/// bundle, never in a shared temporary folder, and only the last `keep` are kept: an agent that
/// loops for hours does not fill the disk.
public enum AgentShots {
    /// How many screenshots stay on disk; older ones are deleted at each write.
    public static let keep = 20

    /// Saves `png` as a new file and deletes all but the newest `keep`. Names are the time in
    /// nanoseconds, zero-padded so that name order is age order; a name that would not be newer
    /// than the newest one already there (a clock step back, two shots in one tick) is bumped
    /// past it.
    public static func write(_ png: Data, in bundle: VMBundle) throws -> URL {
        let directory = bundle.agentShotsURL
        try PrivateDirectory.ensure(directory)
        // `ensure` checks the owner, not the type: a symlink planted there is refused here.
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NidoError.unsafePath(directory.path)
        }
        var shots = try existing(in: directory)
        var stamp = clock_gettime_nsec_np(CLOCK_REALTIME)
        if let newest = shots.last, stamp <= newest.stamp { stamp = newest.stamp + 1 }
        let url = directory.appendingPathComponent(name(stamp))
        try PrivateFile.writeAtomically(png, to: url)
        shots.append((stamp, url.lastPathComponent))
        for old in shots.dropLast(keep) {
            _ = Darwin.unlink(directory.appendingPathComponent(old.name).path)
        }
        return url
    }

    private static func name(_ stamp: UInt64) -> String {
        let digits = String(stamp)
        return String(repeating: "0", count: max(0, 20 - digits.count)) + digits + ".png"
    }

    /// The screenshots in `directory`, oldest first. Anything else there (a temporary file of
    /// an interrupted write, a file someone put there) is left alone and not counted.
    private static func existing(in directory: URL) throws -> [(stamp: UInt64, name: String)] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap { entry -> (stamp: UInt64, name: String)? in
                guard entry.count == 24, entry.hasSuffix(".png"),
                    let stamp = UInt64(entry.prefix(20)), name(stamp) == entry
                else { return nil }
                return (stamp, entry)
            }
            .sorted { $0.stamp < $1.stamp }
    }
}
